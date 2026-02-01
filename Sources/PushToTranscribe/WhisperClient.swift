import Foundation
import AVFoundation

class WhisperClient {
    private let apiKey: String
    private let apiURL = "https://api.openai.com/v1/audio/transcriptions"
    private var accumulatedTranscript = ""
    private var audioBuffer = Data()
    private weak var settingsManager: SettingsManager?
    private let logger = DiagnosticLogger.shared
    private var requestStartTime: Date?
    
    // Callback for when transcription is complete
    var onTranscriptionComplete: ((String) -> Void)?
    
    init(apiKey: String, settingsManager: SettingsManager) {
        self.apiKey = apiKey
        self.settingsManager = settingsManager
        
        // Log API key status (masked for security)
        let maskedKey = apiKey.prefix(10) + "..." + apiKey.suffix(4)
        logger.info("WhisperClient initialized with API key: \(maskedKey)", category: "API")
    }
    
    func accumulateAudio(audioData: Data) {
        audioBuffer.append(audioData)
        logger.debug("Accumulated \(audioBuffer.count) bytes of audio", category: "Audio")
    }
    
    func processAccumulatedAudio() {
        guard !audioBuffer.isEmpty else {
            logger.warning("No audio data to process - buffer is empty", category: "Audio")
            onTranscriptionComplete?("")
            return
        }
        
        let durationSeconds = Double(audioBuffer.count) / (16000.0 * 2.0) // 16kHz, 16-bit (2 bytes)
        logger.info("Processing \(audioBuffer.count) bytes (~\(String(format: "%.2f", durationSeconds))s) of audio", category: "Audio")
        
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
            logger.error("Failed to create WAV file from audio data", category: "API")
            onTranscriptionComplete?("")
            return
        }
        
        logger.info("Created WAV file: \(wavData.count) bytes", category: "API")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        
        guard let url = URL(string: apiURL) else {
            logger.error("Invalid API URL: \(apiURL)", category: "API")
            onTranscriptionComplete?("")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 // 60 second timeout
        
        let model = settingsManager?.transcriptionModel ?? "gpt-4o-mini-transcribe"
        let language = settingsManager?.language ?? "en"
        
        logger.info("Sending API request to OpenAI", category: "API")
        logger.info("Model: \(model), Language: \(language)", category: "API")
        
        let body = createMultipartBody(audioData: wavData, boundary: boundary)
        request.httpBody = body
        
        logger.info("Request body size: \(body.count) bytes", category: "API")
        
        // Record start time
        requestStartTime = Date()
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                self?.logger.error("WhisperClient deallocated during request", category: "API")
                return
            }
            
            // Calculate request duration
            let duration: String
            if let startTime = self.requestStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                duration = String(format: "%.2f", elapsed)
            } else {
                duration = "unknown"
            }
            
            if let error = error {
                self.logger.error("Network error after \(duration)s: \(error.localizedDescription)", category: "API")
                
                // Check for specific error types
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain {
                    switch nsError.code {
                    case NSURLErrorTimedOut:
                        self.logger.error("Request timed out - server may be slow or unreachable", category: "API")
                    case NSURLErrorNotConnectedToInternet:
                        self.logger.error("No internet connection", category: "API")
                    case NSURLErrorNetworkConnectionLost:
                        self.logger.error("Network connection was lost", category: "API")
                    case NSURLErrorSecureConnectionFailed:
                        self.logger.error("SSL/TLS connection failed", category: "API")
                    default:
                        self.logger.error("NSURLError code: \(nsError.code)", category: "API")
                    }
                }
                
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?("")
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                self.logger.error("Invalid response type (not HTTP) after \(duration)s", category: "API")
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?("")
                }
                return
            }
            
            self.logger.info("Response received in \(duration)s - Status: \(httpResponse.statusCode)", category: "API")
            
            // Log response headers for debugging
            if httpResponse.statusCode != 200 {
                self.logger.warning("Response headers: \(httpResponse.allHeaderFields)", category: "API")
            }
            
            guard let data = data else {
                self.logger.error("No data in response body", category: "API")
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?("")
                }
                return
            }
            
            self.logger.info("Response body size: \(data.count) bytes", category: "API")
            
            // Log raw response for non-200 status codes
            if httpResponse.statusCode != 200 {
                if let responseString = String(data: data, encoding: .utf8) {
                    self.logger.error("Error response body: \(responseString)", category: "API")
                }
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?("")
                }
                return
            }
            
            // Handle the response on a background thread to avoid main thread blocking
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleTranscriptionResponse(data: data)
            }
        }.resume()
        
        logger.info("Request sent, waiting for response...", category: "API")
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
        
        // Add model parameter - default to fastest model
        let model = settingsManager?.transcriptionModel ?? "gpt-4o-mini-transcribe"
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
        logger.debug("Parsing response JSON...", category: "API")
        
        // First, try to log the raw response for debugging
        if let rawString = String(data: data, encoding: .utf8) {
            let preview = rawString.count > 200 ? String(rawString.prefix(200)) + "..." : rawString
            logger.debug("Raw response: \(preview)", category: "API")
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                // Check for error response
                if let error = json["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Unknown error"
                    let type = error["type"] as? String ?? "unknown"
                    let code = error["code"] as? String ?? "none"
                    logger.error("API Error - Type: \(type), Code: \(code), Message: \(message)", category: "API")
                    
                    DispatchQueue.main.async {
                        self.onTranscriptionComplete?("")
                    }
                    return
                }
                
                // Extract transcription text
                if let text = json["text"] as? String {
                    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.success("Transcription received: \(cleanText.count) characters", category: "API")
                    logger.info("Text: \(cleanText)", category: "Transcription")
                    
                    // Update using the existing callback mechanism on main thread
                    DispatchQueue.main.async {
                        self.onTranscriptionComplete?(cleanText)
                    }
                } else {
                    logger.error("Response JSON missing 'text' field. Keys: \(json.keys.joined(separator: ", "))", category: "API")
                    DispatchQueue.main.async {
                        self.onTranscriptionComplete?("")
                    }
                }
            } else {
                logger.error("Failed to parse response as JSON dictionary", category: "API")
                DispatchQueue.main.async {
                    self.onTranscriptionComplete?("")
                }
            }
        } catch {
            logger.error("JSON parsing error: \(error.localizedDescription)", category: "API")
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