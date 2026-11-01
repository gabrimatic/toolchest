import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File helpers shared by the Finder features. Nothing here ever overwrites an existing file.
enum FileNaming {
    /// Whether anything is at `path`, without following a final symlink (a dangling symlink exists).
    static func lexists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// A real directory, not a symlink to one.
    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// "name.ext", or "name 2.ext", "name 3.ext"…: the first that doesn't exist in `folder`.
    /// Only a suggestion: the actual create or move is exclusive and retries on a race.
    static func unique(_ name: String, in folder: URL, exists: (URL) -> Bool = { FileNaming.lexists($0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 2...10_000 {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return folder.appendingPathComponent("\(base) \(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    /// Creates a new file named `name` (or a numbered variant) in `folder` with `data`.
    /// O_CREAT|O_EXCL|O_NOFOLLOW: it never overwrites and never writes through a symlink.
    static func createNew(_ name: String, in folder: URL, data: Data) -> URL? {
        for _ in 0..<50 {
            let url = unique(name, in: folder)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            let ok = data.withUnsafeBytes { buffer in
                buffer.isEmpty || write(fd, buffer.baseAddress, buffer.count) == buffer.count
            }
            close(fd)
            if ok { return url }
            unlink(url.path)
            return nil
        }
        return nil
    }

    /// Moves a finished file from a private staging place to `name` (or a numbered variant) in
    /// `folder` with renamex_np(RENAME_EXCL): an existing file or symlink is never replaced.
    static func placeExclusively(_ staged: URL, as name: String, in folder: URL) -> URL? {
        for _ in 0..<50 {
            let target = unique(name, in: folder)
            if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    /// Streams the file through SHA-256, so large files don't load into memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum StripResult: Equatable { case written(URL), noLocation, unsupported, failed(String) }

    static func hasLocation(_ url: URL) -> Bool? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        for index in 0..<count {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               properties[kCGImagePropertyGPSDictionary] != nil { return true }
        }
        return false
    }

    /// Writes "<name> (no location).<ext>" next to the original without GPS metadata. The original
    /// is never touched. The copy is written in a private staging folder on the same volume, checked,
    /// and only then moved into place exclusively, so nothing can be swapped in under it.
    static func stripLocation(_ url: URL) -> StripResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            return .unsupported
        }
        guard hasLocation(url) == true else { return .noLocation }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let name = "\(url.deletingPathExtension().lastPathComponent) (no location)" + (ext.isEmpty ? "" : ".\(ext)")
        guard let staging = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                         appropriateFor: folder, create: true) else {
            return .failed("Couldn’t prepare a private place to write the copy")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("copy" + (ext.isEmpty ? "" : ".\(ext)"))
        let count = CGImageSourceGetCount(source)

        // Excluding GPS alone makes ImageIO drop every other tag too (dates, camera, orientation),
        // so the source metadata is handed over explicitly and only GPS is left out.
        var written = false
        if count == 1, let destination = CGImageDestinationCreateWithURL(staged as CFURL, type, 1, nil) {
            var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                options[kCGImageDestinationMetadata] = metadata
                options[kCGImageDestinationMergeMetadata] = true
            }
            written = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
        }
        if !written {
            // Lossless copy not supported for this format: re-encode at full quality without GPS.
            try? FileManager.default.removeItem(at: staged)
            guard let fallback = CGImageDestinationCreateWithURL(staged as CFURL, type, max(count, 1), nil) else { return .unsupported }
            for index in 0..<count {
                var properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
                properties[kCGImagePropertyGPSDictionary] = kCFNull
                properties[kCGImageDestinationLossyCompressionQuality] = 1.0
                CGImageDestinationAddImageFromSource(fallback, source, index, properties as CFDictionary)
            }
            guard CGImageDestinationFinalize(fallback) else { return .failed("ImageIO could not write the copy") }
        }
        guard hasLocation(staged) == false else { return .failed("The copy still had location data, so it was discarded") }
        guard let placed = placeExclusively(staged, as: name, in: folder) else {
            return .failed("Couldn’t save the copy in \(folder.lastPathComponent)")
        }
        return .written(placed)
    }
}

/// Paths of recently closed Finder windows and tabs, newest last.
struct ClosedFolderHistory: Sendable {
    private(set) var entries: [(path: String, at: TimeInterval)] = []
    let limit = 20

    mutating func push(_ path: String, now: TimeInterval) {
        // The same folder reported twice in a moment (⌘W and the window's own close) is one close.
        if let last = entries.last, last.path == path, now - last.at < 1.5 { return }
        entries.append((path, now))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// The newest entry that still exists.
    mutating func pop(exists: (String) -> Bool) -> String? {
        while let last = entries.popLast() {
            if exists(last.path) { return last.path }
        }
        return nil
    }

    var isEmpty: Bool { entries.isEmpty }
}
