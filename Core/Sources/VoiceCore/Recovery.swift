import Foundation

/// Finds recordings that never made it into the history, and makes their files readable.
///
/// A recording is written to disk as it is made, but a WAV's header only gets its final
/// sizes when the file is closed. After a crash, a force quit or a power cut the header
/// still says the file is empty, even though the audio is all there.
public enum Recovery {
    /// WAVs in the folder that no history row points at, oldest first.
    public static func orphans(in folder: URL, known: Set<String>) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "wav" && !known.contains($0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// When the recording started: recordings are named by their start time in milliseconds.
    public static func recordedAt(_ url: URL) -> Date {
        if let ms = Double(url.deletingPathExtension().lastPathComponent) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.creationDate] as? Date ?? Date()
    }

    /// Rewrites the RIFF and data sizes from the file's length. Returns the seconds of audio
    /// the file holds, or nil when it isn't a WAV this can read.
    @discardableResult
    public static func repairHeader(_ url: URL) -> Double? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 12 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: Int(min(fileSize, 64 * 1024))),
              head.count >= 12,
              String(decoding: head[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: head[8..<12], as: UTF8.self) == "WAVE" else { return nil }

        var offset = 12
        var blockAlign = 0
        var byteRate = 0
        while offset + 8 <= head.count {
            let id = String(decoding: head[offset..<offset + 4], as: UTF8.self)
            let size = Int(le32(head, offset + 4))
            if id == "fmt ", offset + 8 + 16 <= head.count {
                byteRate = Int(le32(head, offset + 8 + 8))
                blockAlign = Int(le16(head, offset + 8 + 12))
            }
            if id == "data" {
                guard blockAlign > 0, byteRate > 0 else { return nil }
                let dataStart = UInt64(offset + 8)
                let available = fileSize > dataStart ? fileSize - dataStart : 0
                let dataSize = available - available % UInt64(blockAlign)
                if UInt64(size) != dataSize {
                    write32(handle, at: UInt64(offset + 4), UInt32(clamping: dataSize))
                    write32(handle, at: 4, UInt32(clamping: dataStart + dataSize - 8))
                }
                return Double(dataSize) / Double(byteRate)
            }
            // Chunks are padded to an even length.
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    private static func le32(_ data: Data, _ at: Int) -> UInt32 {
        let start = data.startIndex + at
        return data[start..<start + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private static func le16(_ data: Data, _ at: Int) -> UInt16 {
        let start = data.startIndex + at
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    private static func write32(_ handle: FileHandle, at offset: UInt64, _ value: UInt32) {
        var little = value.littleEndian
        try? handle.seek(toOffset: offset)
        handle.write(Data(bytes: &little, count: 4))
    }
}

extension Dictation {
    /// A history row that keeps only the audio: too short to transcribe, or a transcription
    /// that failed and can be tried again from the menu.
    public init(audio: URL, createdAt: Date = Date(), duration: Double, mode: Mode, whisperModel: String,
                error: String, origin: Origin? = nil) {
        self.init(id: UUID().uuidString, createdAt: createdAt, audioPath: audio.path, duration: duration,
                  mode: mode, whisperModel: whisperModel, rawText: "", finalText: "", cleanupModel: nil,
                  cleanupSystem: nil, timings: Timings(), segments: [], error: error, origin: origin)
    }
}
