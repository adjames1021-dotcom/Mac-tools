import Foundation
import AVFoundation
import ImageIO

/// MP3 → FLAC: Apple's afconvert decodes and encodes 24-bit FLAC, then the MP3's ID3 tags and
/// cover art are written into the FLAC as Vorbis comments and PICTURE blocks.
enum FLACConverter {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Tags {
        var comments: [(String, String)] = []
        var pictures: [Data] = []
    }

    // ID3v2 frame → Vorbis comment field name.
    static let fieldNames: [String: String] = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TPE2": "ALBUMARTIST", "TALB": "ALBUM",
        "TYER": "DATE", "TDRC": "DATE", "TCON": "GENRE", "TCOM": "COMPOSER", "COMM": "COMMENT",
        "USLT": "LYRICS", "TBPM": "BPM", "TPUB": "LABEL", "TSRC": "ISRC", "TCOP": "COPYRIGHT",
        "TENC": "ENCODED-BY", "TIT1": "GROUPING", "TIT3": "SUBTITLE", "TSOP": "ARTISTSORT",
        "TSOA": "ALBUMSORT", "TSOT": "TITLESORT", "TSO2": "ALBUMARTISTSORT", "TCMP": "COMPILATION",
        "TEXT": "LYRICIST", "TPE3": "CONDUCTOR", "TPE4": "REMIXER", "TKEY": "KEY",
        "TLAN": "LANGUAGE", "TMOO": "MOOD", "TOPE": "ORIGINALARTIST", "TDOR": "ORIGINALDATE",
        "TORY": "ORIGINALDATE",
    ]

    static func convert(_ input: URL, to output: URL) async throws {
        let tags = try await readTags(input)
        let temp = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: temp) }

        // flac/3 = encode from 24-bit source: keeps the decoder's output without rounding to 16-bit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "flac", "-d", "flac/3", input.path, temp.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let message = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let flac = try Data(contentsOf: temp)
        try withMetadata(flac, tags).write(to: output, options: .atomic)
    }

    static func readTags(_ url: URL) async throws -> Tags {
        var tags = Tags()
        for item in try await AVURLAsset(url: url).load(.metadata) {
            guard let raw = item.identifier?.rawValue, raw.hasPrefix("id3/") else { continue }
            let frame = String(raw.dropFirst(4))
            if frame == "APIC" {
                if let data = try await item.load(.dataValue) { tags.pictures.append(data) }
                continue
            }
            guard let value = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            if frame == "TXXX" {
                // User-defined frames (ReplayGain, MusicBrainz IDs…) carry their own name.
                if let name = try await item.load(.extraAttributes)?[AVMetadataExtraAttributeKey(rawValue: "info")] as? String, !name.isEmpty {
                    tags.comments.append((name.uppercased(), value))
                }
                continue
            }
            if frame == "TRCK" || frame == "TPOS" {
                // "3/12" → number + total.
                let parts = value.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                let (number, total) = frame == "TRCK" ? ("TRACKNUMBER", "TRACKTOTAL") : ("DISCNUMBER", "DISCTOTAL")
                if let first = parts.first, !first.isEmpty { tags.comments.append((number, first)) }
                if parts.count > 1, !parts[1].isEmpty { tags.comments.append((total, parts[1])) }
                continue
            }
            if let field = fieldNames[frame] { tags.comments.append((field, value)) }
        }
        return tags
    }

    /// Replaces the FLAC's comment and picture blocks with ours, keeping STREAMINFO, SEEKTABLE etc.
    static func withMetadata(_ flac: Data, _ tags: Tags) throws -> Data {
        let bytes = [UInt8](flac)
        guard bytes.count > 8, bytes[0..<4] == [0x66, 0x4C, 0x61, 0x43] else { throw Failure("afconvert didn't produce a FLAC file") }
        var blocks: [(type: UInt8, body: [UInt8])] = []
        var pos = 4
        var last = false
        while !last {
            guard pos + 4 <= bytes.count else { throw Failure("Damaged FLAC header") }
            last = bytes[pos] & 0x80 != 0
            let type = bytes[pos] & 0x7F
            let length = Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            guard pos + 4 + length <= bytes.count else { throw Failure("Damaged FLAC header") }
            if type != 1, type != 4, type != 6 { blocks.append((type, Array(bytes[pos + 4 ..< pos + 4 + length]))) }
            pos += 4 + length
        }

        blocks.append((4, vorbisComment(tags.comments)))
        for (index, image) in tags.pictures.enumerated() {
            let body = pictureBlock(image, type: index == 0 ? 3 : 0)
            if body.count < 1 << 24 { blocks.append((6, body)) }  // FLAC caps a block at 16 MB
        }

        var out: [UInt8] = [0x66, 0x4C, 0x61, 0x43]
        for (index, block) in blocks.enumerated() {
            out.append((index == blocks.count - 1 ? 0x80 : 0) | block.type)
            out += be(UInt32(block.body.count)).suffix(3)
            out += block.body
        }
        out += bytes[pos...]
        return Data(out)
    }

    static func vorbisComment(_ comments: [(String, String)]) -> [UInt8] {
        let vendor = Array("MacTools".utf8)
        var out = le(UInt32(vendor.count)) + vendor + le(UInt32(comments.count))
        for (key, value) in comments {
            let entry = Array("\(key)=\(value)".utf8)
            out += le(UInt32(entry.count)) + entry
        }
        return out
    }

    static func pictureBlock(_ image: Data, type: UInt32) -> [UInt8] {
        let mime: String
        switch image.prefix(4) {
        case Data([0x89, 0x50, 0x4E, 0x47]): mime = "image/png"
        case Data([0x47, 0x49, 0x46, 0x38]): mime = "image/gif"
        default: mime = "image/jpeg"
        }
        var width: UInt32 = 0, height: UInt32 = 0, depth: UInt32 = 24
        if let source = CGImageSourceCreateWithData(image as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (props[kCGImagePropertyPixelWidth] as? UInt32) ?? 0
            height = (props[kCGImagePropertyPixelHeight] as? UInt32) ?? 0
            if let bits = props[kCGImagePropertyDepth] as? UInt32, let alpha = props[kCGImagePropertyHasAlpha] as? Bool {
                depth = bits * (alpha ? 4 : 3)
            }
        }
        let mimeBytes = Array(mime.utf8)
        return be(type) + be(UInt32(mimeBytes.count)) + mimeBytes + be(0)
            + be(width) + be(height) + be(depth) + be(0) + be(UInt32(image.count)) + [UInt8](image)
    }

    private static func be(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    private static func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
}
