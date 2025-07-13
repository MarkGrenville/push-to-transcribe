import AVFoundation
import Foundation

class AudioRecordingManager: NSObject {
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var inputFormat: AVAudioFormat
    private var outputFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    
    var onAudioDataReceived: ((Data) -> Void)?
    
    override init() {
        inputNode = audioEngine.inputNode
        inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Create the desired output format (16kHz, mono, 16-bit PCM)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                       sampleRate: 16000, 
                                       channels: 1, 
                                       interleaved: false) else {
            fatalError("Failed to create audio format")
        }
        outputFormat = format
        
        super.init()
        
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        // Create audio converter for format conversion
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("❌ Failed to create audio converter")
            print("📊 Input format: \(inputFormat)")
            print("📊 Output format: \(outputFormat)")
            return
        }
        
        audioConverter = converter
        
        // Use larger buffer size for better quality (4096 samples = ~85ms at 48kHz)
        let bufferSize: AVAudioFrameCount = 4096
        
        // Install tap on input node with input format, then convert
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
            self?.processAudioBuffer(buffer)
        }
        
        print("✅ Audio engine setup complete")
        print("📊 Input: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
        print("📊 Output: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount) channels")
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else {
            print("❌ Audio converter not available")
            return
        }
        
        // Calculate output frame count for resampling
        let inputSampleRate = inputFormat.sampleRate
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
        
        print("🛑 Audio recording stopped")
        
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