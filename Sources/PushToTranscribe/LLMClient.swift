import Foundation

class LLMClient {
    private let apiKey: String
    private let apiURL = "https://api.openai.com/v1/chat/completions"
    private let logger = DiagnosticLogger.shared
    
    init(apiKey: String) {
        self.apiKey = apiKey
        let maskedKey = apiKey.prefix(10) + "..." + apiKey.suffix(4)
        logger.info("LLMClient initialized with API key: \(maskedKey)", category: "LLM")
    }
    
    func cleanupText(_ text: String, prompt: String, model: String, completion: @escaping (String) -> Void) {
        logger.info("Starting text cleanup with model: \(model)", category: "LLM")
        logger.debug("Input text: \(text.prefix(100))...", category: "LLM")
        
        guard let url = URL(string: apiURL) else {
            logger.error("Invalid API URL: \(apiURL)", category: "LLM")
            completion(text) // Return original text on error
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3, // Lower temperature for more consistent cleanup
            "max_tokens": 4096
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            logger.error("Failed to serialize request body: \(error.localizedDescription)", category: "LLM")
            completion(text) // Return original text on error
            return
        }
        
        let requestStartTime = Date()
        logger.info("Sending cleanup request to OpenAI...", category: "LLM")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                completion(text)
                return
            }
            
            let duration = String(format: "%.2f", Date().timeIntervalSince(requestStartTime))
            
            if let error = error {
                self.logger.error("Network error after \(duration)s: \(error.localizedDescription)", category: "LLM")
                DispatchQueue.main.async {
                    completion(text) // Return original text on error
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                self.logger.error("Invalid response type after \(duration)s", category: "LLM")
                DispatchQueue.main.async {
                    completion(text)
                }
                return
            }
            
            self.logger.info("Response received in \(duration)s - Status: \(httpResponse.statusCode)", category: "LLM")
            
            guard let data = data else {
                self.logger.error("No data in response body", category: "LLM")
                DispatchQueue.main.async {
                    completion(text)
                }
                return
            }
            
            // Parse the response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Check for error response
                    if let error = json["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "Unknown error"
                        let type = error["type"] as? String ?? "unknown"
                        self.logger.error("API Error - Type: \(type), Message: \(message)", category: "LLM")
                        DispatchQueue.main.async {
                            completion(text) // Return original text on error
                        }
                        return
                    }
                    
                    // Extract the cleaned text from the response
                    if let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        
                        let cleanedText = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.logger.success("Text cleaned successfully: \(cleanedText.count) characters", category: "LLM")
                        self.logger.info("Cleaned text: \(cleanedText)", category: "LLM")
                        
                        DispatchQueue.main.async {
                            completion(cleanedText)
                        }
                    } else {
                        self.logger.error("Failed to parse response structure", category: "LLM")
                        if let responseString = String(data: data, encoding: .utf8) {
                            self.logger.debug("Raw response: \(responseString.prefix(500))", category: "LLM")
                        }
                        DispatchQueue.main.async {
                            completion(text)
                        }
                    }
                }
            } catch {
                self.logger.error("JSON parsing error: \(error.localizedDescription)", category: "LLM")
                DispatchQueue.main.async {
                    completion(text)
                }
            }
        }.resume()
    }
}
