import AVFoundation
import Foundation

class AudioRecordingManager: NSObject {
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var audioFormat: AVAudioFormat
    
    var onAudioDataReceived: ((Data) -> Void)?
    
    override init() {
        inputNode = audioEngine.inputNode
        audioFormat = inputNode.outputFormat(forBus: 0)
        
        super.init()
        
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        // Configure audio format for Whisper API (16kHz, mono, 16-bit)
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                        sampleRate: 16000, 
                                        channels: 1, 
                                        interleaved: false)
        
        guard desiredFormat != nil else {
            print("Failed to create audio format")
            return
        }
        
        // Install tap on input node to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: audioFormat) { [weak self] (buffer, time) in
            self?.processAudioBuffer(buffer)
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        
        let frameCount = Int(buffer.frameLength)
        var audioData = Data()
        
        // Convert float samples to 16-bit PCM
        for i in 0..<frameCount {
            let sample = Int16(channelData[i] * 32767.0)
            audioData.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }
        
        // Send audio data to callback
        onAudioDataReceived?(audioData)
    }
    
    func startRecording() {
        do {
            // Request microphone permission
            requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.startAudioEngine()
                } else {
                    print("Microphone permission denied")
                }
            }
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        
        // Reinstall tap for next recording
        setupAudioEngine()
    }
    
    private func startAudioEngine() {
        do {
            try audioEngine.start()
            print("Audio engine started")
        } catch {
            print("Failed to start audio engine: \(error)")
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