import Foundation
import ImageIO
import AppKit
import Darwin
import CoreImage
import UniformTypeIdentifiers

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
    static let legacyAlbum = URL.applicationSupportDirectory.appending(path: "PenCam/Album", directoryHint: .isDirectory)

    private static let legacyMigrationLock = NSLock()
    private static let legacyMigrationKey = "didCopyLegacyAlbumToPhotoFolder"
    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]

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
        let keys = Self.fileKeys.union([.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey])
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        ).compactMap { item -> (photo: Photo, date: Date)? in
            guard Photo.supports(item), let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink == false else {
                return nil
            }
            let date = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate
            return (Photo(url: item), date ?? .distantPast)
        }
        .sorted { first, second in
            if first.date != second.date { return first.date > second.date }
            return first.photo.name.localizedStandardCompare(second.photo.name) == .orderedAscending
        }
        .map(\.photo)
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let fd = Darwin.open(url.path(percentEncoded: false), O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else {
                continuation.finish()
                return
            }
            let monitor = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .global(qos: .utility)
            )
            monitor.setEventHandler { continuation.yield() }
            monitor.setCancelHandler { Darwin.close(fd) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.activate()
        }
    }

    func migrateLegacyPhotos(from legacyFolder: URL = Self.legacyAlbum,
                             defaults: UserDefaults = .standard) throws -> FileResult? {
        Self.legacyMigrationLock.lock()
        defer { Self.legacyMigrationLock.unlock() }
        guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return nil }

        let files = FileManager.default
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries: [URL]
        do {
            entries = try files.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: Array(directoryKeys),
                                                    options: .skipsHiddenFiles)
        } catch CocoaError.fileReadNoSuchFile {
            entries = []
        }
        let sources = try entries.flatMap { entry -> [URL] in
            let data = try entry.resourceValues(forKeys: directoryKeys)
            guard data.isDirectory == true, data.isSymbolicLink == false else { return [] }
            return try files.contentsOfDirectory(at: entry, includingPropertiesForKeys: Array(Self.fileKeys),
                                                 options: .skipsHiddenFiles).filter { item in
                guard Photo.supports(item) else { return false }
                let values = try item.resourceValues(forKeys: Self.fileKeys)
                return values.isRegularFile == true && values.isSymbolicLink == false
            }
        }
        let result = save(sources, validatingImages: true, skippingIdenticalCopies: true)
        if result.failed == 0 { defaults.set(true, forKey: Self.legacyMigrationKey) }
        return result
    }

    func save(_ urls: [URL], validatingImages: Bool = false, skippingIdenticalCopies: Bool = false,
              mirroringJPEG: Bool = false) -> FileResult {
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
                if mirroringJPEG && ["jpg", "jpeg"].contains(fileExtension.lowercased()) {
                    try mirrorJPEG(at: staging)
                }
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
                        if skippingIdenticalCopies,
                           let values = try? target.resourceValues(forKeys: Self.fileKeys),
                           values.isRegularFile == true, values.isSymbolicLink == false,
                           files.contentsEqual(atPath: staging.path, andPath: target.path) {
                            saved += 1
                            break
                        }
                        suffix += 1
                    }
                }
            } catch {
                continue
            }
        }
        return FileResult(saved: saved, failed: urls.count - saved)
    }

    private func mirrorJPEG(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value
            ?? Int32(CGImagePropertyOrientation.up.rawValue)
        let transform = CIImage(cgImage: image).orientationTransform(forExifOrientation: orientation)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let upright = bounds.applying(transform)
        let data = NSMutableData()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: Int(upright.width), height: Int(upright.height),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.translateBy(x: upright.width, y: 0)
        bitmap.scaleBy(x: -1, y: 1)
        bitmap.translateBy(x: -upright.minX, y: -upright.minY)
        bitmap.concatenate(transform)
        bitmap.draw(image, in: bounds)
        guard let output = bitmap.makeImage() else { throw CocoaError(.fileWriteUnknown) }

        properties[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue
        properties[kCGImagePropertyPixelWidth as String] = output.width
        properties[kCGImagePropertyPixelHeight as String] = output.height
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = output.width
            exif[kCGImagePropertyExifPixelYDimension as String] = output.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: url)
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
