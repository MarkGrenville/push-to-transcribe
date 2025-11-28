import AVFoundation
import Foundation
import AppKit

class AudioRecordingManager: NSObject {
    private var audioEngine = AVAudioEngine()
    private var outputFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var isRecording = false
    
    var onAudioDataReceived: ((Data) -> Void)?
    var onRecordingStopped: (() -> Void)?
    
    override init() {
        // Create the desired output format (16kHz, mono, 16-bit PCM)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                       sampleRate: 16000, 
                                       channels: 1, 
                                       interleaved: false) else {
            fatalError("Failed to create audio format")
        }
        outputFormat = format
        
        super.init()
    }
    
    private func setupAudioEngine() -> Bool {
        // Always get fresh input node and format (handles microphone changes)
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Validate that we have a valid input format (this can fail if microphone permission isn't fully active)
        // A sample rate of 0 or channel count of 0 indicates the microphone isn't accessible
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("❌ Invalid input format - microphone may not be available")
            print("   Sample rate: \(inputFormat.sampleRate), channels: \(inputFormat.channelCount)")
            print("💡 Please restart the app after granting microphone permission")
            showMicrophoneRestartAlert()
            return false
        }
        
        print("✅ Audio input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channel(s)")
        
        // Create audio converter for format conversion
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("❌ Failed to create audio converter")
            return false
        }
        
        audioConverter = converter
        
        // Use smaller buffer size for lower latency and more frequent callbacks
        // This ensures we capture audio more frequently and don't lose data at the end
        let bufferSize: AVAudioFrameCount = 2048
        
        // Remove any existing tap first to avoid conflicts
        inputNode.removeTap(onBus: 0)
        
        // Install tap on input node with current input format
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            
            // Process all buffers while recording - don't filter here
            // The isRecording check happens in stopRecording to ensure we 
            // capture all in-flight buffers before stopping
            self.processAudioBuffer(buffer)
        }
        
        return true
    }
    
    private func showMicrophoneRestartAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Restart Required"
            alert.informativeText = "Microphone permission was recently granted. Please restart Push to Transcribe for it to take effect."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit & Restart")
            alert.addButton(withTitle: "Later")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Relaunch the app
                let url = Bundle.main.bundleURL
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                    NSApp.terminate(nil)
                }
            }
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else {
            print("❌ Audio converter not available")
            return
        }
        
        // Calculate output frame count for resampling
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = outputFormat.sampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = UInt32(Double(buffer.frameLength) * ratio)
        
        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            print("❌ Failed to create output buffer")
            return
        }
        
        // Convert audio format
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            print("❌ Audio conversion error: \(error)")
            return
        }
        
        // Extract PCM data from converted buffer
        guard let int16Data = outputBuffer.int16ChannelData?[0] else {
            print("❌ Failed to get int16 channel data")
            return
        }
        
        let frameCount = Int(outputBuffer.frameLength)
        let audioData = Data(bytes: int16Data, count: frameCount * MemoryLayout<Int16>.size)
        
        // Send converted audio data to callback
        onAudioDataReceived?(audioData)
    }
    
    func startRecording() {
        isRecording = true
        
        // Request microphone permission
        requestMicrophonePermission { [weak self] granted in
            if granted {
                self?.startAudioEngine()
            } else {
                print("Microphone permission denied")
            }
        }
    }
    
    func stopRecording() {
        guard isRecording else {
            print("⚠️ stopRecording called but not recording")
            return
        }
        
        print("🛑 Stop recording requested - waiting for final audio buffers...")
        isRecording = false
        
        // CRITICAL FIX: Add a delay to ensure any in-flight audio buffers are processed
        // The audio engine processes buffers asynchronously, so when we stop immediately,
        // the last ~100-200ms of audio can be lost. This delay ensures we capture
        // the complete speech including the final words/sentence.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            
            // Now stop the audio engine after buffers have been flushed
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            
            print("🛑 Audio engine stopped - all buffers captured")
            
            // Reset the audio engine for next recording (handles microphone changes)
            self.audioEngine = AVAudioEngine()
            
            // Notify that recording has fully stopped and all audio is captured
            self.onRecordingStopped?()
        }
    }
    
    private func startAudioEngine() {
        do {
            // Setup audio engine with current default microphone
            if !setupAudioEngine() {
                print("❌ Failed to setup audio engine")
                return
            }
            
            try audioEngine.start()
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            // Try to recover by resetting the engine
            audioEngine = AVAudioEngine()
        }
    }
    
    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        completion(granted)
                    }
                }
            @unknown default:
                completion(false)
            }
        } else {
            // For older macOS versions, assume permission is granted
            // The system will prompt automatically when we try to use the microphone
            completion(true)
        }
    }
} 