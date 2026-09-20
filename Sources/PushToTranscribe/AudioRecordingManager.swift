import AVFoundation
import Foundation
import AppKit

/// One finished recording: 16 kHz mono float samples.
struct AudioClip {
    let samples: [Float]
    let sampleRate: Double
    /// How long the key was held. The clip itself is a little shorter at the
    /// front (the input device takes ~160 ms to deliver its first block) and a
    /// little longer at the back (the tail), so this is the only honest measure
    /// of whether the user meant to record.
    let heldDuration: TimeInterval

    var duration: TimeInterval { Double(samples.count) / sampleRate }
    var isEmpty: Bool { samples.isEmpty }

    /// Loudest sample in the clip. Used to tell a real utterance from a room.
    var peakAmplitude: Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }
}

/// Captures microphone audio as 16 kHz mono float samples.
///
/// The microphone is opened only while a key is held, so macOS shows the orange
/// input indicator exactly when the app is recording and at no other time.
///
/// Everything that can be set up without opening the device — instantiating the
/// input node, building the sample-rate converter, installing the tap — is done
/// once at launch, because measurement showed none of it activates the
/// microphone; only `AVAudioEngine.start()` does. That leaves ~160 ms between
/// the key going down and the first block of audio arriving.
///
/// Critically, the capture gate is independent of the engine. The gate opens on
/// key-down and everything that arrives while it is open is kept, whenever the
/// device gets around to delivering it. An earlier version tied capture to
/// engine start/stop ordering on a shared queue, and when those two raced the
/// recording either came back empty or never stopped at all.
final class AudioRecordingManager: NSObject {
    static let sampleRate: Double = 16000

    /// How long to keep capturing after key-up. The input device delivers audio
    /// in ~20-50 ms blocks, so the last word's tail is still in flight.
    private static let tailSeconds: Double = 0.15

    /// Grace period before the microphone is released. Long enough that
    /// releasing and immediately pressing again does not pay for a full
    /// device restart, short enough that the indicator still tracks recording.
    private static let releaseDelay: Double = 0.4

    /// A press whose key-up is never delivered used to record until the app was
    /// restarted — the archive holds a 19-minute, 36 MB recording from one.
    private static let maxRecordingSeconds: Double = 300

    /// Only runs while a recording is open, to catch the device dying mid-press.
    private static let healthCheckInterval: TimeInterval = 1.0

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    /// Guards every field below it. Held only for array appends, never across a
    /// call into AVFoundation or a callback.
    private let bufferLock = NSLock()
    private var isCapturing = false
    private var captured: [Float] = []
    private var captureStartedAt = Date.distantPast
    private var captureStoppedAt = Date.distantPast
    private var captureMode: HotkeyType = .normal

    private let logger = DiagnosticLogger.shared

    /// Every engine start/stop/reconfigure happens here, serially, so a device
    /// change, a health check and a key press can never fight over the engine.
    private let engineQueue = DispatchQueue(label: "com.pushToTranscribe.audioEngine", qos: .userInitiated)
    private var healthTimer: DispatchSourceTimer?
    private var hasWarnedAboutMicrophone = false
    private var hasPermission = false
    private var lastEngineRebuild = Date.distantPast

    /// Fired on the main queue once a recording is complete and gathered, with
    /// the mode the press was started in. The mode travels with the clip rather
    /// than being read at completion time, because by then the next recording
    /// may already have started in a different mode.
    var onRecordingFinished: ((AudioClip, HotkeyType) -> Void)?
    /// Fired on the main queue when a press ran past `maxRecordingSeconds`.
    var onRecordingTruncated: (() -> Void)?

    private var maxDurationWorkItem: DispatchWorkItem?
    /// The scheduled end of the current recording's tail. Flushed early if a
    /// new press arrives before it fires.
    private var pendingStop: DispatchWorkItem?
    /// The scheduled release of the microphone. Cancelled if a new press
    /// arrives first, so back-to-back dictation does not restart the device.
    private var pendingRelease: DispatchWorkItem?

    override init() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioRecordingManager.sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            fatalError("Failed to create audio format")
        }
        outputFormat = format
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    deinit {
        healthTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    /// Asks for microphone permission and builds everything that does not
    /// require opening the device. Does not light the input indicator.
    func prepare() {
        requestMicrophonePermission { [weak self] granted in
            guard let self = self else { return }
            self.hasPermission = granted
            guard granted else {
                self.logger.error("Microphone permission denied — recording is unavailable", category: "Audio")
                return
            }
            self.engineQueue.async {
                if self.prepareTap() {
                    self.logger.success("Audio pipeline ready — microphone opens only while recording", category: "Audio")
                }
            }
        }
    }

    /// Opens the capture gate and asks for the microphone. Returns immediately;
    /// audio starts flowing into the open gate as soon as the device delivers.
    func startRecording(mode: HotkeyType) {
        // A press arriving inside the previous recording's tail must not be
        // dropped. Close the old clip now and start cleanly.
        if let stop = pendingStop {
            stop.cancel()
            pendingStop = nil
            logger.info("New press during the previous tail — closing that clip early", category: "Audio")
            finishCapture()
        }

        // Keep the device if it is still winding down from the last recording.
        pendingRelease?.cancel()
        pendingRelease = nil

        bufferLock.lock()
        if isCapturing {
            bufferLock.unlock()
            logger.warning("startRecording called while already capturing — ignoring", category: "Audio")
            return
        }
        isCapturing = true
        captureStartedAt = Date()
        captureMode = mode
        captured.removeAll(keepingCapacity: true)
        captured.reserveCapacity(Int(AudioRecordingManager.sampleRate * 30))
        bufferLock.unlock()

        scheduleMaxDurationStop()
        startHealthTimer()

        engineQueue.async { [weak self] in
            self?.ensureEngineRunning(reason: "recording")
        }

        logger.info("Capture started", category: "Audio")
    }

    /// Closes the gate after a short tail and hands the clip over. Calling it
    /// when no capture is open is harmless — hotkey recovery paths rely on that.
    func stopRecording() {
        bufferLock.lock()
        let wasCapturing = isCapturing
        bufferLock.unlock()

        guard wasCapturing else {
            logger.debug("stopRecording called with no capture open — ignoring", category: "Audio")
            return
        }

        // A second stop for the same press — the hotkey release and the
        // watchdog both firing, say — must not schedule a second close.
        guard pendingStop == nil else { return }
        captureStoppedAt = Date()

        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil

        let stop = DispatchWorkItem { [weak self] in
            self?.pendingStop = nil
            self?.finishCapture()
        }
        pendingStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioRecordingManager.tailSeconds, execute: stop)
    }

    /// Closes the gate, hands the clip over and schedules the microphone's
    /// release. Idempotent. Main thread only.
    private func finishCapture() {
        bufferLock.lock()
        guard isCapturing else {
            bufferLock.unlock()
            return
        }
        isCapturing = false
        let samples = captured
        // Measured key-down to key-up, so neither the device's start-up delay
        // nor the tail distorts what the user actually did.
        let held = captureStoppedAt.timeIntervalSince(captureStartedAt)
        let mode = captureMode
        captured = []
        bufferLock.unlock()

        stopHealthTimer()
        scheduleMicrophoneRelease()

        let clip = AudioClip(samples: samples,
                             sampleRate: AudioRecordingManager.sampleRate,
                             heldDuration: held)
        logger.info("Capture complete: \(String(format: "%.2f", clip.duration))s audio from a \(String(format: "%.2f", held))s press", category: "Audio")
        onRecordingFinished?(clip, mode)
    }

    /// True while the gate is open.
    var isRecording: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return isCapturing
    }

    private func scheduleMaxDurationStop() {
        maxDurationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.logger.warning("Recording hit the \(Int(AudioRecordingManager.maxRecordingSeconds))s ceiling — stopping", category: "Audio")
            self.onRecordingTruncated?()
            self.stopRecording()
        }
        maxDurationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioRecordingManager.maxRecordingSeconds, execute: item)
    }

    /// Main thread only.
    private func scheduleMicrophoneRelease() {
        pendingRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingRelease = nil
            // A press may have re-opened the gate while this was queued.
            guard !self.isRecording else { return }
            self.engineQueue.async { self.stopEngine() }
        }
        pendingRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioRecordingManager.releaseDelay, execute: release)
    }

    // MARK: - Engine

    /// Instantiates the input node, builds the converter and installs the tap
    /// for the current input device. None of this opens the microphone.
    /// Called on `engineQueue` only.
    @discardableResult
    private func prepareTap() -> Bool {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("No usable microphone (\(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch)", category: "Audio")
            warnAboutMicrophoneOnce()
            return false
        }

        if converterInputFormat != inputFormat || converter == nil {
            guard let made = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                logger.error("Failed to create audio converter from \(inputFormat)", category: "Audio")
                return false
            }
            converter = made
            converterInputFormat = inputFormat

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            logger.info("Input tap ready: \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch", category: "Audio")
        }

        return true
    }

    /// Opens the microphone. Called on `engineQueue` only.
    private func ensureEngineRunning(reason: String) {
        guard hasPermission else { return }
        guard !engine.isRunning else { return }
        guard prepareTap() else { return }

        let began = Date()
        do {
            try engine.start()
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            logger.info("Microphone opened in \(ms)ms (\(reason))", category: "Audio")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)", category: "Audio")
            // A wedged engine object cannot be restarted; build a fresh one so
            // the next attempt — or the health timer — has a clean slate.
            rebuildEngine()
        }
    }

    /// Releases the microphone. Called on `engineQueue` only.
    private func stopEngine() {
        guard engine.isRunning else { return }
        engine.stop()
        logger.info("Microphone released", category: "Audio")
    }

    /// Called on `engineQueue` only.
    private func rebuildEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        converter = nil
        converterInputFormat = nil
    }

    /// The input device changed under us — mic unplugged, Bluetooth headset
    /// connected, sample rate renegotiated. The tap's format is now stale, so
    /// rebuild it; only reopen the microphone if a recording is actually open.
    @objc private func handleConfigurationChange() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            // Belt and braces against a rebuild that itself provokes another
            // change notification.
            guard Date().timeIntervalSince(self.lastEngineRebuild) > 1.0 else { return }
            self.lastEngineRebuild = Date()

            self.logger.warning("Audio configuration changed — rebuilding the input tap", category: "Audio")
            self.rebuildEngine()
            self.prepareTap()

            if self.isRecording {
                self.ensureEngineRunning(reason: "configuration change mid-recording")
            }
        }
    }

    /// Runs only while a recording is open. Catches the device dying mid-press
    /// — sleep/wake, a mic being unplugged — which would otherwise produce a
    /// recording that is silently truncated at the point of failure.
    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + AudioRecordingManager.healthCheckInterval,
                       repeating: AudioRecordingManager.healthCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            guard !self.engine.isRunning else { return }
            self.logger.warning("Health check: microphone stopped mid-recording — reopening", category: "Audio")
            self.ensureEngineRunning(reason: "health check")
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    // MARK: - Capture

    /// Runs on the audio thread. Converts to 16 kHz mono and appends to the
    /// recording. Anything arriving while the gate is shut is dropped.
    private func append(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        let wanted = isCapturing
        bufferLock.unlock()
        guard wanted, let converter = converter else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The converter must see this buffer exactly once. Reporting `.haveData`
        // unconditionally makes it re-consume the same block to fill the output
        // capacity, which duplicates audio.
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error = error {
            logger.error("Audio conversion failed: \(error.localizedDescription)", category: "Audio")
            return
        }

        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: frames)

        bufferLock.lock()
        // Re-checked under the lock: the gate may have closed while converting,
        // and appending after `finishCapture` copied the buffer would leak this
        // recording's audio into the next one.
        if isCapturing {
            captured.append(contentsOf: samples)
        }
        bufferLock.unlock()
    }

    // MARK: - Permission

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        guard #available(macOS 14.0, *) else {
            completion(true)
            return
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            completion(false)
        }
    }

    private func warnAboutMicrophoneOnce() {
        guard !hasWarnedAboutMicrophone else { return }
        hasWarnedAboutMicrophone = true

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Microphone Unavailable"
            alert.informativeText = "Push to Transcribe could not open the microphone. If you just granted permission, restart the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit & Restart")
            alert.addButton(withTitle: "Later")

            if alert.runModal() == .alertFirstButtonReturn {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
