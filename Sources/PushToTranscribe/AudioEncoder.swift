import AVFoundation
import Foundation

/// An audio payload ready to be uploaded.
struct EncodedAudio {
    let data: Data
    /// File extension, also used as the archive extension.
    let fileExtension: String
    let mimeType: String
}

/// Turns captured samples into the smallest file the transcription API accepts.
///
/// The app used to upload raw 16-bit PCM in a WAV container: 32 KB for every
/// second of speech. At an average of 19 seconds per recording that is ~600 KB,
/// and a minute-long note is nearly 2 MB — on a slow uplink that is tens of
/// seconds of upload before the model has heard anything. AAC at 24 kbps is
/// ~3 KB/s, an 11x reduction, and is indistinguishable to a speech model at
/// this sample rate.
enum AudioEncoder {
    /// Plenty for 16 kHz mono speech; the upload, not the bitrate, is the
    /// bottleneck being solved here.
    private static let bitRate = 24000

    private static let logger = DiagnosticLogger.shared

    /// Encodes to AAC in an MPEG-4 container, falling back to WAV if the
    /// system encoder is unavailable for any reason. Never returns nil for a
    /// non-empty clip.
    static func encode(_ clip: AudioClip) -> EncodedAudio? {
        guard !clip.isEmpty else { return nil }

        if let aac = encodeAAC(clip) {
            let wavSize = clip.samples.count * 2 + 44
            let saved = wavSize > 0 ? 100 - (aac.count * 100 / wavSize) : 0
            logger.info("Encoded \(String(format: "%.1f", clip.duration))s to \(aac.count / 1024)KB AAC (\(saved)% smaller than WAV)", category: "Audio")
            return EncodedAudio(data: aac, fileExtension: "m4a", mimeType: "audio/mp4")
        }

        logger.warning("AAC encoding unavailable — falling back to WAV", category: "Audio")
        return wav(clip)
    }

    /// The uncompressed form. Every transcription API accepts it, so it is what
    /// the client falls back to if a compressed upload is ever rejected.
    static func wav(_ clip: AudioClip) -> EncodedAudio {
        EncodedAudio(data: encodeWAV(clip), fileExtension: "wav", mimeType: "audio/wav")
    }

    private static func encodeAAC(_ clip: AudioClip) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]

        // Written inside its own function so the AVAudioFile is released — and
        // the container's header finalised — before the bytes are read back.
        func write() throws {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)

            // Chunked so a long recording never needs a second copy of itself
            // as one giant PCM buffer.
            let chunkFrames = 16384
            var offset = 0
            while offset < clip.samples.count {
                let count = min(chunkFrames, clip.samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw CocoaError(.fileWriteUnknown)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                clip.samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress! + offset, count: count)
                }
                try file.write(from: buffer)
                offset += count
            }
        }

        do {
            try write()
        } catch {
            logger.error("AAC encoding failed: \(error.localizedDescription)", category: "Audio")
            return nil
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            logger.error("AAC encoding produced no data", category: "Audio")
            return nil
        }

        guard let frames = try? AVAudioFile(forReading: url).length else { return data }
        return removingPadding(from: data, expectedFrames: frames) ?? data
    }

    /// AVAudioFile reserves ~24 KB of `free` padding so it can grow the moov
    /// atom in place. For a 19-second recording that padding is almost half the
    /// upload, and it is all zero bytes. Removing it means fixing up the chunk
    /// offset tables that point past it.
    ///
    /// The result is decoded and frame-counted before being accepted, so a bug
    /// here costs the optimisation rather than the recording.
    private static func removingPadding(from data: Data, expectedFrames: AVAudioFramePosition) -> Data? {
        guard let stripped = strippingFreeAtoms(data) else { return nil }
        guard stripped.count < data.count else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-verify-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        guard (try? stripped.write(to: url)) != nil,
              let check = try? AVAudioFile(forReading: url),
              check.length == expectedFrames else {
            logger.warning("Padding removal did not verify — uploading the padded file", category: "Audio")
            return nil
        }

        return stripped
    }

    /// Walks the top-level atoms, drops every `free`/`skip` one, and shifts the
    /// absolute chunk offsets in `stco`/`co64` by however many bytes were
    /// removed ahead of them. Returns nil on anything it does not fully
    /// understand.
    private static func strippingFreeAtoms(_ data: Data) -> Data? {
        var removed: [(start: Int, length: Int)] = []
        var kept: [Range<Int>] = []
        var moovRange: Range<Int>?

        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(be32(data, offset))
            let type = atomType(data, offset)
            // 0 means "to end of file"; 1 means a 64-bit size field. Neither
            // appears in what AVAudioFile writes, so bail rather than guess.
            guard size >= 8, offset + size <= data.count else { return nil }

            if type == "free" || type == "skip" {
                removed.append((offset, size))
            } else {
                if type == "moov" { moovRange = offset..<(offset + size) }
                kept.append(offset..<(offset + size))
            }
            offset += size
        }

        guard offset == data.count, !removed.isEmpty, let moov = moovRange else { return nil }

        var output = Data(capacity: data.count)
        for range in kept { output.append(data[range]) }

        // Where moov landed in the output, so the offset tables can be patched
        // in place.
        var movedMoovStart = 0
        for range in kept {
            if range == moov { break }
            movedMoovStart += range.count
        }

        func bytesRemovedBefore(_ position: Int) -> Int {
            removed.filter { $0.start < position }.reduce(0) { $0 + $1.length }
        }

        var ok = true
        forEachChunkOffsetTable(in: output, moovStart: movedMoovStart) { tableStart, is64 in
            guard ok else { return }
            let count = Int(be32(output, tableStart + 12))
            let entrySize = is64 ? 8 : 4
            let first = tableStart + 16
            guard first + count * entrySize <= tableStart + Int(be32(output, tableStart)) else {
                ok = false
                return
            }
            for i in 0..<count {
                let at = first + i * entrySize
                if is64 {
                    let value = be64(output, at)
                    let shifted = value - UInt64(bytesRemovedBefore(Int(value)))
                    writeBE64(&output, at, shifted)
                } else {
                    let value = be32(output, at)
                    let shifted = value - UInt32(bytesRemovedBefore(Int(value)))
                    writeBE32(&output, at, shifted)
                }
            }
        }

        return ok ? output : nil
    }

    /// Recursive descent to every `stco`/`co64` inside moov. Only the container
    /// atoms that can hold one are descended into.
    private static func forEachChunkOffsetTable(in data: Data, moovStart: Int, _ body: (Int, Bool) -> Void) {
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

        func walk(_ start: Int, _ end: Int) {
            var offset = start
            while offset + 8 <= end {
                let size = Int(be32(data, offset))
                let type = atomType(data, offset)
                guard size >= 8, offset + size <= end else { return }
                if type == "stco" || type == "co64" {
                    body(offset, type == "co64")
                } else if containers.contains(type) {
                    walk(offset + 8, offset + size)
                }
                offset += size
            }
        }

        let moovSize = Int(be32(data, moovStart))
        walk(moovStart + 8, moovStart + moovSize)
    }

    // MARK: - Big-endian helpers

    private static func atomType(_ data: Data, _ offset: Int) -> String {
        String(bytes: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], encoding: .ascii) ?? ""
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        (UInt64(be32(data, offset)) << 32) | UInt64(be32(data, offset + 4))
    }

    private static func writeBE32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        let i = data.startIndex + offset
        data[i] = UInt8((value >> 24) & 0xFF)
        data[i + 1] = UInt8((value >> 16) & 0xFF)
        data[i + 2] = UInt8((value >> 8) & 0xFF)
        data[i + 3] = UInt8(value & 0xFF)
    }

    private static func writeBE64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        writeBE32(&data, offset, UInt32(value >> 32))
        writeBE32(&data, offset + 4, UInt32(value & 0xFFFF_FFFF))
    }

    private static func encodeWAV(_ clip: AudioClip) -> Data {
        var pcm = Data(capacity: clip.samples.count * 2)
        for sample in clip.samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        let sampleRate = UInt32(clip.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(pcm.count)

        var wav = Data()
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }

        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(dataSize + 36).littleEndian)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian)
        append(channels.littleEndian)
        append(sampleRate.littleEndian)
        append((sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8).littleEndian)
        append((channels * bitsPerSample / 8).littleEndian)
        append(bitsPerSample.littleEndian)
        wav.append(contentsOf: Array("data".utf8))
        append(dataSize.littleEndian)
        wav.append(pcm)

        return wav
    }
}
