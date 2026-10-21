import CryptoKit
import Foundation

/// Tells whether an Aerial video file is still Apple's original, without any network access.
///
/// When macOS downloads an Aerial it stores the server's ETag on the file (extended attribute
/// `LastETag`, e.g. `"99627DD80E9ACA43158DDA2E2428CF42-8"`). Apple serves Aerials from S3, where a
/// multipart ETag is the MD5 of the concatenated MD5s of each part, followed by the part count, so it
/// can be recomputed from the file and compared.
///
/// The part size depends on how each file was uploaded. Checked against Apple's server on
/// 2026-10-21: newer Aerials use 64 MiB parts and some 2023 ones 100,000,000-byte parts. Every
/// candidate size that gives the recorded part count is tried, in one read of the file.
public enum AerialChecksum {
    public static let partSizes = [64 * 1024 * 1024, 100_000_000,
                                   8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024, 128 * 1024 * 1024,
                                   50_000_000, 128_000_000]

    /// The ETag macOS recorded when it downloaded the file, without quotes. nil if there is none.
    public static func recordedETag(of url: URL) -> String? {
        let name = "LastETag"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length else { return nil }
        let value = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        return value.isEmpty ? nil : value.uppercased()
    }

    /// The plain MD5 of the whole file, as S3 reports for a single-part upload.
    public static func etag(of url: URL) throws -> String {
        try etags(of: url, partSizes: [])[0]!
    }

    /// The multipart ETag of the file for one part size.
    public static func etag(of url: URL, partSize: Int) throws -> String {
        try etags(of: url, partSizes: [partSize])[partSize]!
    }

    /// Reads the file once and returns its ETag for each part size; key 0 is the plain MD5.
    static func etags(of url: URL, partSizes: [Int]) throws -> [Int: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        struct Running { var md5 = Insecure.MD5(); var filled = 0; var digests = Data(); var parts = 0 }
        var whole = Insecure.MD5()
        var running = Dictionary(uniqueKeysWithValues: partSizes.map { ($0, Running()) })
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if partSizes.isEmpty { whole.update(data: chunk) }
            for size in partSizes {
                var state = running[size]!
                var offset = chunk.startIndex
                while offset < chunk.endIndex {
                    let take = min(size - state.filled, chunk.endIndex - offset)
                    state.md5.update(data: chunk[offset..<(offset + take)])
                    state.filled += take
                    offset += take
                    if state.filled == size {
                        state.digests.append(contentsOf: state.md5.finalize())
                        state.parts += 1
                        state = Running(md5: Insecure.MD5(), filled: 0, digests: state.digests, parts: state.parts)
                    }
                }
                running[size] = state
            }
        }
        var result: [Int: String] = [:]
        if partSizes.isEmpty { result[0] = hex(whole.finalize()) }
        for (size, var state) in running {
            if state.filled > 0 {
                state.digests.append(contentsOf: state.md5.finalize())
                state.parts += 1
            }
            result[size] = hex(Insecure.MD5.hash(data: state.digests)) + "-\(state.parts)"
        }
        return result
    }

    /// Whether `file` has the contents described by `expectedETag` (normally the `LastETag` macOS
    /// recorded on the Aerial). Only part sizes that give the recorded part count for this file's size
    /// are tried, so a file of another size is rejected without reading it.
    public static func matches(_ file: URL, expectedETag: String, partSizes: [Int] = partSizes) -> Bool {
        let expected = expectedETag.uppercased()
        let pieces = expected.split(separator: "-")
        guard pieces.count == 2, let parts = Int(pieces[1]) else {
            return (try? etag(of: file)) == expected
        }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) else { return false }
        let candidates = partSizes.filter { (size + $0 - 1) / $0 == parts }
        guard !candidates.isEmpty, let etags = try? etags(of: file, partSizes: candidates) else { return false }
        return etags.values.contains(expected)
    }

    /// Whether the Aerial file is Apple's original. nil when macOS recorded no ETag on it, so it can't
    /// be checked.
    public static func isAppleOriginal(_ file: URL) -> Bool? {
        guard let expected = recordedETag(of: file) else { return nil }
        return matches(file, expectedETag: expected)
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02X", $0) }.joined()
    }
}
