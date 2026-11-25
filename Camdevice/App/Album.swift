import Foundation
import ImageIO
import AppKit

struct Photo: Identifiable, Equatable {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif", "dng"
    ]

    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var size: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func supports(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static let thumbnails: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    func image(maxSize: Int = 400) -> NSImage? {
        let cacheKey = url as NSURL
        if maxSize == 400, let cached = Self.thumbnails.object(forKey: cacheKey) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: .zero)
        if maxSize == 400 { Self.thumbnails.setObject(result, forKey: cacheKey) }
        return result
    }

}

struct PhotoFolder: Sendable {
    struct FileResult: Sendable {
        let saved: Int
        let failed: Int
    }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(bookmark: Data) throws {
        var stale = false
        url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                      bookmarkDataIsStale: &stale)
    }

    func bookmark() throws -> Data {
        try url.bookmarkData(options: .minimalBookmark)
    }

    func photos() throws -> [Photo] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        ).compactMap { item -> (photo: Photo, date: Date)? in
            guard Photo.supports(item), let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink == false else {
                return nil
            }
            return (Photo(url: item), values.creationDate ?? .distantPast)
        }
        .sorted { first, second in
            if first.date != second.date { return first.date > second.date }
            return first.photo.name.localizedStandardCompare(second.photo.name) == .orderedAscending
        }
        .map(\.photo)
    }

    func save(_ urls: [URL], validatingImages: Bool = false) -> FileResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        var saved = 0
        for source in urls {
            let sourceAccess = source.startAccessingSecurityScopedResource()
            defer { if sourceAccess { source.stopAccessingSecurityScopedResource() } }
            let fileExtension = source.pathExtension
            let temporaryName = ".camdevice-" + UUID().uuidString
            let staging = url.appending(path: fileExtension.isEmpty ? temporaryName : temporaryName + "." + fileExtension)
            defer { try? files.removeItem(at: staging) }

            do {
                try copyFile(at: source, to: staging)
                if validatingImages {
                    guard let image = CGImageSourceCreateWithURL(staging as CFURL, nil),
                          CGImageSourceCreateThumbnailAtIndex(image, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 24
                          ] as CFDictionary) != nil else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                let stem = source.deletingPathExtension().lastPathComponent
                var suffix = 1
                while true {
                    let name: String
                    if suffix == 1 {
                        name = source.lastPathComponent
                    } else {
                        let numbered = "\(stem) (\(suffix))"
                        name = fileExtension.isEmpty ? numbered : numbered + "." + fileExtension
                    }
                    let target = url.appending(path: name, directoryHint: .notDirectory)
                    do {
                        try files.moveItem(at: staging, to: target)
                        saved += 1
                        break
                    } catch CocoaError.fileWriteFileExists {
                        suffix += 1
                    }
                }
            } catch {
                continue
            }
        }
        return FileResult(saved: saved, failed: urls.count - saved)
    }

    private func copyFile(at source: URL, to target: URL) throws {
        let files = FileManager.default
        do {
            try files.copyItem(at: source, to: target)
        } catch {
            // A file provider may need to make the selected file available first.
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            var readError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &readError) { readableURL in
                do { try files.copyItem(at: readableURL, to: target) }
                catch { copyError = error }
            }
            if let error = readError ?? copyError { throw error }
        }
    }
}
