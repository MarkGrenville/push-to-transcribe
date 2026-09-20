import Foundation
import AVFoundation

enum APIErrorKind {
    case quotaExceeded
    case rateLimited
    case authFailed
    case networkError
    case serverError
    case other

    var isBillingRelated: Bool {
        self == .quotaExceeded
    }
}

struct TranscriptionFailure {
    let kind: APIErrorKind
    let message: String
    /// Whether retrying the identical request could plausibly succeed. A lost
    /// connection is retryable; a rejected API key is not.
    let isRetryable: Bool
    /// The server rejected the audio container rather than the request. Worth
    /// one attempt in the universally-accepted format before giving up.
    let isFormatRejection: Bool

    var isBillingRelated: Bool { kind.isBillingRelated }

    init(kind: APIErrorKind, message: String, isRetryable: Bool, isFormatRejection: Bool = false) {
        self.kind = kind
        self.message = message
        self.isRetryable = isRetryable
        self.isFormatRejection = isFormatRejection
    }
}

/// A recording waiting to be, or being, transcribed. Held onto after a failure
/// so the audio is never the thing that gets lost.
struct TranscriptionJob {
    let sessionId: String
    let audio: EncodedAudio
    let mode: HotkeyType
    /// The samples the upload was made from, kept so the recording can be
    /// re-encoded rather than lost if the server refuses the container.
    let clip: AudioClip
    let createdAt: Date

    var duration: TimeInterval { clip.duration }

    func reencoded(as audio: EncodedAudio) -> TranscriptionJob {
        TranscriptionJob(sessionId: sessionId, audio: audio, mode: mode, clip: clip, createdAt: createdAt)
    }
}

/// What the client is currently doing, for the menu bar.
enum TranscriptionProgress {
    case uploading(fraction: Double)
    case waitingForNetwork
    case processing
    case retrying(attempt: Int, of: Int)
}

final class WhisperClient: NSObject {
    private var apiKey: String
    private let apiURL = "https://api.openai.com/v1/audio/transcriptions"
    private weak var settingsManager: SettingsManager?
    private let logger = DiagnosticLogger.shared

    /// Total attempts per recording, including the first.
    private let maxAttempts = 3
    /// OpenAI rejects uploads above 25 MB.
    private let maxUploadBytes = 25 * 1024 * 1024

    private var session: URLSession!
    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private let progressLock = NSLock()
    private var lastWarmup = Date.distantPast

    /// The last recording that failed and can still be retried by hand.
    private(set) var pendingRetry: TranscriptionJob?

    /// All callbacks land on the main queue.
    var onTranscriptionComplete: ((String, TranscriptionJob?) -> Void)?
    var onAPIError: ((TranscriptionFailure, TranscriptionJob?) -> Void)?
    var onProgress: ((TranscriptionProgress) -> Void)?

    init(apiKey: String, settingsManager: SettingsManager) {
        self.apiKey = apiKey
        self.settingsManager = settingsManager
        super.init()

        let config = URLSessionConfiguration.default
        // Rather than failing instantly when the machine is offline or the link
        // is flapping, hold the request until there is a usable route.
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 180
        config.networkServiceType = .responsiveData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        if apiKey.isEmpty {
            logger.warning("WhisperClient initialized without API key — set one in Settings", category: "API")
        } else {
            logger.info("WhisperClient initialized with API key: \(Self.mask(apiKey))", category: "API")
        }
    }

    func updateAPIKey(_ newKey: String) {
        apiKey = newKey
        if !newKey.isEmpty {
            logger.info("WhisperClient API key updated: \(Self.mask(newKey))", category: "API")
        }
    }

    private static func mask(_ key: String) -> String {
        guard key.count > 14 else { return "(short key)" }
        return key.prefix(10) + "..." + key.suffix(4)
    }

    // MARK: - Entry points

    /// Encodes and uploads a finished recording.
    func transcribe(_ clip: AudioClip, mode: HotkeyType) {
        guard !apiKey.isEmpty else {
            logger.error("No API key configured — Settings > API Key", category: "API")
            deliverFailure(TranscriptionFailure(kind: .authFailed, message: "No API key configured", isRetryable: false),
                           job: nil)
            return
        }

        guard !clip.isEmpty else {
            logger.warning("Nothing captured — no audio to transcribe", category: "Audio")
            deliverEmpty()
            return
        }

        // A clip always contains pre-roll and tail, so its own length says
        // nothing about intent — only how long the key was held does. A tap is
        // not a dictation, and uploading one gets a hallucinated word pasted
        // into whatever the user was typing in.
        guard clip.heldDuration >= 0.25 else {
            logger.info("Discarding a \(Int(clip.heldDuration * 1000))ms tap — too short to be speech", category: "Audio")
            deliverEmpty()
            return
        }

        // Near-digital-silence means a muted or dead microphone. Deliberately
        // set far below any real speech so a quiet talker is never dropped.
        guard clip.peakAmplitude >= 0.003 else {
            logger.warning("Discarding a silent \(String(format: "%.1f", clip.duration))s recording — is the microphone muted?", category: "Audio")
            deliverEmpty()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let audio = AudioEncoder.encode(clip) else {
                self.deliverFailure(TranscriptionFailure(kind: .other, message: "Could not encode the recording", isRetryable: false),
                                    job: nil)
                return
            }

            guard audio.data.count <= self.maxUploadBytes else {
                let mb = audio.data.count / 1024 / 1024
                self.deliverFailure(TranscriptionFailure(kind: .other, message: "Recording too large to upload (\(mb)MB)", isRetryable: false),
                                    job: nil)
                return
            }

            let job = TranscriptionJob(sessionId: SettingsManager.generateSessionId(),
                                       audio: audio,
                                       mode: mode,
                                       clip: clip,
                                       createdAt: Date())
            self.settingsManager?.saveAudioToArchive(audio.data,
                                                     fileExtension: audio.fileExtension,
                                                     sessionId: job.sessionId)
            self.send(job, attempt: 1)
        }
    }

    /// Re-uploads the last failed recording. The audio is still in memory, so
    /// this costs nothing but the request.
    func retryPending() {
        guard let job = pendingRetry else {
            logger.warning("Retry requested but nothing is pending", category: "API")
            return
        }
        pendingRetry = nil
        logger.info("Manual retry of \(job.sessionId) (\(String(format: "%.1f", job.duration))s)", category: "API")
        send(job, attempt: 1)
    }

    func clearPendingRetry() {
        pendingRetry = nil
    }

    /// Establishes the TLS connection to the API while the user is still
    /// talking, so the upload does not begin with a handshake. On a slow link
    /// that handshake alone is several hundred milliseconds. Fire and forget —
    /// the result is irrelevant, only the pooled connection matters.
    func warmUpConnection() {
        guard !apiKey.isEmpty else { return }
        guard Date().timeIntervalSince(lastWarmup) > 60 else { return }
        lastWarmup = Date()

        guard let url = URL(string: "https://api.openai.com/v1/models") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Request

    private func send(_ job: TranscriptionJob, attempt: Int) {
        guard let url = URL(string: apiURL) else {
            deliverFailure(TranscriptionFailure(kind: .other, message: "Invalid API URL", isRetryable: false), job: job)
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let model = settingsManager?.transcriptionModel ?? "gpt-transcribe"
        let body = multipartBody(job: job, boundary: boundary, model: model)

        logger.info("Uploading \(body.count / 1024)KB (\(String(format: "%.1f", job.duration))s audio, model \(model), attempt \(attempt)/\(maxAttempts))", category: "API")

        if attempt > 1 {
            report(.retrying(attempt: attempt, of: maxAttempts))
        } else {
            report(.uploading(fraction: 0))
        }

        let started = Date()
        let task = session.uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self = self else { return }
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))

            if let error = error {
                let failure = Self.classify(networkError: error)
                self.logger.error("Network error after \(elapsed)s: \(failure.message)", category: "API")
                self.handle(failure, job: job, attempt: attempt)
                return
            }

            guard let http = response as? HTTPURLResponse, let data = data else {
                self.handle(TranscriptionFailure(kind: .networkError, message: "No response from the server", isRetryable: true),
                            job: job, attempt: attempt)
                return
            }

            self.logger.info("HTTP \(http.statusCode) in \(elapsed)s (\(data.count) bytes)", category: "API")

            guard http.statusCode == 200 else {
                let failure = Self.classify(status: http.statusCode, body: data)
                self.logger.error("API error \(http.statusCode): \(failure.message)", category: "API")
                self.handle(failure, job: job, attempt: attempt)
                return
            }

            self.parse(data, job: job, attempt: attempt)
        }

        setProgressHandler(for: task.taskIdentifier) { [weak self] fraction in
            self?.report(.uploading(fraction: fraction))
        }
        task.resume()
    }

    private func parse(_ data: Data, job: TranscriptionJob, attempt: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            handle(TranscriptionFailure(kind: .other, message: "Could not read the server's response", isRetryable: true),
                   job: job, attempt: attempt)
            return
        }

        if let error = json["error"] as? [String: Any] {
            handle(Self.classify(errorObject: error, status: 200), job: job, attempt: attempt)
            return
        }

        guard let text = json["text"] as? String else {
            logger.error("Response had no 'text' field. Keys: \(json.keys.joined(separator: ", "))", category: "API")
            handle(TranscriptionFailure(kind: .other, message: "Server returned no transcript", isRetryable: true),
                   job: job, attempt: attempt)
            return
        }

        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pinning `language` is a hint, not a constraint: on near-silence these
        // models still occasionally answer in another script entirely. Four of
        // 3,617 archived transcriptions came back as Korean, Chinese or Urdu,
        // every one a two-to-seven character hallucination. When the user has
        // declared a Latin-script language, that output is never what they said
        // — and auto-paste would put it straight into their document.
        if isConfiguredForLatinScript, !clean.isEmpty, !Self.isLatinScript(clean) {
            logger.warning("Discarding non-Latin transcript \(clean.debugDescription) — language is set to \(settingsManager?.language ?? "en")", category: "API")
            DispatchQueue.main.async { [weak self] in
                self?.onTranscriptionComplete?("", nil)
            }
            return
        }

        logger.success("Transcribed \(clean.count) characters", category: "API")
        logger.info("Text: \(clean)", category: "Transcription")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only this job's own success clears it. A different recording
            // succeeding says nothing about whether the parked one is still
            // worth retrying — and throwing it away would lose the audio.
            if self.pendingRetry?.sessionId == job.sessionId {
                self.pendingRetry = nil
            }
            self.onTranscriptionComplete?(clean, job)
        }
    }

    /// Retries transient failures automatically before bothering the user, then
    /// parks the audio so it can still be retried by hand.
    private func handle(_ failure: TranscriptionFailure, job: TranscriptionJob, attempt: Int) {
        if failure.isFormatRejection, job.audio.fileExtension != "wav" {
            logger.warning("Server rejected \(job.audio.fileExtension) — re-sending as WAV", category: "API")
            send(job.reencoded(as: AudioEncoder.wav(job.clip)), attempt: 1)
            return
        }

        if failure.isRetryable && attempt < maxAttempts {
            let delay = pow(2.0, Double(attempt - 1))   // 1s, then 2s
            logger.warning("Retrying in \(Int(delay))s after: \(failure.message)", category: "API")
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.send(job, attempt: attempt + 1)
            }
            return
        }

        logger.error("Giving up after \(attempt) attempt(s): \(failure.message)", category: "API")
        deliverFailure(failure, job: job)
    }

    private func deliverFailure(_ failure: TranscriptionFailure, job: TranscriptionJob?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Park audio a retry could actually fix. A non-retryable failure
            // leaves any older parked recording alone rather than discarding a
            // recording that is still recoverable.
            if failure.isRetryable, let job = job {
                self.pendingRetry = job
            }
            self.onAPIError?(failure, job)
        }
    }

    private func deliverEmpty() {
        DispatchQueue.main.async { [weak self] in
            self?.onTranscriptionComplete?("", nil)
        }
    }

    private func report(_ progress: TranscriptionProgress) {
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(progress)
        }
    }

    /// Only meaningful for languages actually written in Latin script — the
    /// check would reject every correct result for, say, Japanese.
    private var isConfiguredForLatinScript: Bool {
        let language = settingsManager?.language ?? "en"
        return !["auto", "zh", "ja", "ko", "ru", "ar", "he", "hi", "th", "el", "uk", "fa", "ur", "bn", "ta"].contains(language)
    }

    /// True when at least half the letters are Latin. Punctuation- or
    /// digit-only output is left alone.
    static func isLatinScript(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        // 0x0041-0x024F spans Basic Latin, Latin-1 Supplement and Latin
        // Extended-A/B, so accented English and European spellings all pass.
        let latin = letters.filter { $0.value < 0x0250 }
        return Double(latin.count) / Double(letters.count) >= 0.5
    }

    // MARK: - Error classification

    private static func classify(networkError: Error) -> TranscriptionFailure {
        let nsError = networkError as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return TranscriptionFailure(kind: .networkError, message: networkError.localizedDescription, isRetryable: true)
        }

        switch nsError.code {
        case NSURLErrorTimedOut:
            return TranscriptionFailure(kind: .networkError, message: "Request timed out", isRetryable: true)
        case NSURLErrorNotConnectedToInternet:
            return TranscriptionFailure(kind: .networkError, message: "No internet connection", isRetryable: true)
        case NSURLErrorNetworkConnectionLost:
            return TranscriptionFailure(kind: .networkError, message: "Connection was lost", isRetryable: true)
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return TranscriptionFailure(kind: .networkError, message: "Could not reach OpenAI", isRetryable: true)
        case NSURLErrorSecureConnectionFailed:
            return TranscriptionFailure(kind: .networkError, message: "Secure connection failed", isRetryable: true)
        case NSURLErrorCancelled:
            return TranscriptionFailure(kind: .networkError, message: "Request cancelled", isRetryable: false)
        default:
            return TranscriptionFailure(kind: .networkError, message: networkError.localizedDescription, isRetryable: true)
        }
    }

    private static func classify(status: Int, body: Data) -> TranscriptionFailure {
        if let raw = String(data: body, encoding: .utf8), !raw.isEmpty {
            DiagnosticLogger.shared.debug("Error body: \(raw.prefix(500))", category: "API")
        }

        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            return classify(errorObject: error, status: status)
        }

        return TranscriptionFailure(kind: kind(for: status),
                                    message: "API error (HTTP \(status))",
                                    isRetryable: isRetryable(status))
    }

    private static func classify(errorObject: [String: Any], status: Int) -> TranscriptionFailure {
        let message = errorObject["message"] as? String ?? "Unknown error"
        let code = errorObject["code"] as? String ?? ""
        let type = errorObject["type"] as? String ?? ""
        let lowered = message.lowercased()

        if code == "insufficient_quota" || type == "insufficient_quota"
            || lowered.contains("quota") || lowered.contains("billing") {
            return TranscriptionFailure(kind: .quotaExceeded, message: message, isRetryable: false)
        }

        let looksLikeFormat = status == 400 && ["format", "file type", "unsupported", "could not be decoded", "invalid file"]
            .contains { lowered.contains($0) }

        return TranscriptionFailure(kind: kind(for: status),
                                    message: message,
                                    isRetryable: isRetryable(status),
                                    isFormatRejection: looksLikeFormat)
    }

    private static func kind(for status: Int) -> APIErrorKind {
        switch status {
        case 401, 403: return .authFailed
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .other
        }
    }

    /// Rate limits and server faults clear on their own; a rejected key or a
    /// malformed request will fail identically forever.
    private static func isRetryable(_ status: Int) -> Bool {
        status == 408 || status == 409 || status == 429 || (500...599).contains(status)
    }

    // MARK: - Multipart

    private func multipartBody(job: TranscriptionJob, boundary: String, model: String) -> Data {
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        field("model", model)

        let language = settingsManager?.language ?? "en"
        if language != "auto" {
            // gpt-transcribe takes a "languages" array; the older models take a
            // single "language".
            field(model == "gpt-transcribe" ? "languages[]" : "language", language)
        }

        field("response_format", "json")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(job.audio.fileExtension)\"\r\n".utf8))
        body.append(Data("Content-Type: \(job.audio.mimeType)\r\n\r\n".utf8))
        body.append(job.audio.data)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        return body
    }

    // MARK: - Progress bookkeeping

    private func setProgressHandler(for taskId: Int, _ handler: @escaping (Double) -> Void) {
        progressLock.lock()
        progressHandlers[taskId] = handler
        progressLock.unlock()
    }

    private func progressHandler(for taskId: Int) -> ((Double) -> Void)? {
        progressLock.lock()
        defer { progressLock.unlock() }
        return progressHandlers[taskId]
    }

    private func removeProgressHandler(for taskId: Int) {
        progressLock.lock()
        progressHandlers.removeValue(forKey: taskId)
        progressLock.unlock()
    }
}

extension WhisperClient: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler(for: task.taskIdentifier)?(fraction)
        if fraction >= 1.0 {
            // Upload done; the model is thinking now.
            report(.processing)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        logger.warning("Waiting for a usable network connection...", category: "API")
        report(.waitingForNetwork)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        removeProgressHandler(for: task.taskIdentifier)
    }
}
