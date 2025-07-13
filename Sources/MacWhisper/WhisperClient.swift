import Foundation
import AVFoundation

class WhisperClient {
    private let apiKey: String
    private let apiURL = "https://api.openai.com/v1/audio/transcriptions"
    private var accumulatedTranscript = ""
    private var audioBuffer = Data()
    private weak var settingsManager: SettingsManager?
    
    // Callback for when transcription is complete
    var onTranscriptionComplete: ((String) -> Void)?
    
    init(apiKey: String, settingsManager: SettingsManager) {
        self.apiKey = apiKey
        self.settingsManager = settingsManager
    }
    
    func accumulateAudio(audioData: Data) {
        audioBuffer.append(audioData)
        print("🎵 Accumulated \(audioBuffer.count) bytes of audio")
    }
    
    func processAccumulatedAudio() {
        guard !audioBuffer.isEmpty else {
            print("⚠️ No audio data to process")
            onTranscriptionComplete?("")
            return
        }
        
        let durationSeconds = Double(audioBuffer.count) / (16000.0 * 2.0) // 16kHz, 16-bit (2 bytes)
        print("🎵 Processing \(audioBuffer.count) bytes (~\(String(format: "%.2f", durationSeconds))s) of audio")
        
        // Clear any previous transcript
        accumulatedTranscript = ""
        
        // Send all accumulated audio at once
        let audioToProcess = audioBuffer
        audioBuffer.removeAll()
        
        sendAudioToWhisper(audioData: audioToProcess)
    }
    
    private func sendAudioToWhisper(audioData: Data) {
        // Create a temporary WAV file
        guard let wavData = createWAVFile(from: audioData) else {
            print("Failed to create WAV file")
            return
        }
        
        // Create multipart form data
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let body = createMultipartBody(audioData: wavData, boundary: boundary)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Error: \(error)")
                return
            }
            
            guard let data = data else {
                print("No data received")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("Response status: \(httpResponse.statusCode)")
            }
            
            // Handle the response on a background thread to avoid main thread blocking
            DispatchQueue.global(qos: .userInitiated).async {
                self?.handleTranscriptionResponse(data: data)
            }
        }.resume()
    }
    
    private func createWAVFile(from audioData: Data) -> Data? {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        
        let dataSize = UInt32(audioData.count)
        let fileSize = dataSize + 36
        
        var wavData = Data()
        
        // RIFF header
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: (sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: (channels * bitsPerSample / 8).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wavData.append(audioData)
        
        return wavData
    }
    
    private func createMultipartBody(audioData: Data, boundary: String) -> Data {
        var body = Data()
        
        // Add model parameter
        let model = settingsManager?.transcriptionModel ?? "whisper-1"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        
        // Add language parameter if specified
        let language = settingsManager?.language ?? "en"
        if language != "auto" {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }
        
        // Add response_format parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        
        // Add audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        return body
    }
    
    private func handleTranscriptionResponse(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let text = json["text"] as? String {
                
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("Transcription received: \(cleanText)")
                
                // Update using the existing callback mechanism on main thread
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?(cleanText)
                }
            }
        } catch {
            print("Error parsing transcription response: \(error)")
            // Handle error on main thread
            DispatchQueue.main.async {
                self.onTranscriptionComplete?("")
            }
        }
    }
    
    func getFinalTranscript() -> String {
        return accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func clearTranscript() {
        accumulatedTranscript = ""
        audioBuffer.removeAll()
    }
} 