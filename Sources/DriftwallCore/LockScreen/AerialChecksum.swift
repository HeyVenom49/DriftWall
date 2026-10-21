import CryptoKit
import Foundation

/// Tells whether an Aerial video file is still Apple's original, without any network access.
///
/// When macOS downloads an Aerial it stores the server's ETag on the file (extended attribute
/// `LastETag`, e.g. `"99627DD80E9ACA43158DDA2E2428CF42-8"`). Apple serves Aerials from S3, where a
/// multipart ETag is the MD5 of the concatenated MD5s of each part, followed by the part count. The
/// parts are 64 MiB (verified on macOS 27.0.1 against three untouched downloads), so the ETag can be
/// recomputed from the file and compared.
public enum AerialChecksum {
    public static let partSize = 64 * 1024 * 1024

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

    /// The S3-style ETag of the file's contents: a plain MD5 of the whole file, or with `multipart` the
    /// MD5 of the 64 MiB parts' MD5s followed by the part count.
    public static func etag(of url: URL, multipart: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var whole = Insecure.MD5()
        var partDigests = Data()
        var parts = 0
        while let chunk = try handle.read(upToCount: partSize), !chunk.isEmpty {
            if multipart {
                partDigests.append(contentsOf: Insecure.MD5.hash(data: chunk))
            } else {
                whole.update(data: chunk)
            }
            parts += 1
        }
        if !multipart { return hex(whole.finalize()) }
        return hex(Insecure.MD5.hash(data: partDigests)) + "-\(parts)"
    }

    /// Whether `file` has the contents described by `expectedETag` (normally the `LastETag` macOS
    /// recorded on the Aerial). The part count is checked against the size first, so a different
    /// file is usually rejected without reading it.
    public static func matches(_ file: URL, expectedETag: String) -> Bool {
        let expected = expectedETag.uppercased()
        let pieces = expected.split(separator: "-")
        if pieces.count == 2, let parts = Int(pieces[1]) {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize),
                  (size + partSize - 1) / partSize == parts else { return false }
            return (try? etag(of: file, multipart: true)) == expected
        }
        return (try? etag(of: file, multipart: false)) == expected
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
