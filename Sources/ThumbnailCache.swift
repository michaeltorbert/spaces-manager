import AppKit

struct SpaceThumbnail {
    let image: NSImage
    let capturedAt: Date
}

final class ThumbnailCache {
    private static let thumbnailDirectoryName = "Thumbnails"
    private static let allowedFilenameCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.")
        return set
    }()

    private let captureDelay: TimeInterval = 0.5
    private let maxPixelSize = NSSize(width: 192, height: 120)
    private let ioQueue = DispatchQueue(label: "local.spacesmanager.thumbnail-cache",
                                        qos: .utility)
    private let directoryURL: URL

    private var thumbnails: [String: SpaceThumbnail] = [:]
    private var inFlightKeys = Set<String>()
    private var lastPrunedKeys: Set<String>?

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directoryURL = supportURL
            .appendingPathComponent("SpacesManager", isDirectory: true)
            .appendingPathComponent(Self.thumbnailDirectoryName, isDirectory: true)
    }

    var hasScreenCaptureAccess: Bool {
        Self.hasScreenCaptureAccess
    }

    @discardableResult
    func requestScreenCaptureAccess() -> Bool {
        Self.requestScreenCaptureAccess()
    }

    func loadFromDisk() {
        let directoryURL = self.directoryURL
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.loadThumbnails(from: directoryURL)
            guard !loaded.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (key, thumbnail) in loaded {
                    self.thumbnails[key] = thumbnail
                }
            }
        }
    }

    func thumbnail(for spaceKey: String) -> SpaceThumbnail? {
        thumbnails[spaceKey]
    }

    func capture(spaceKey: String,
                 displayID: String,
                 isCurrent: @escaping () -> Bool = { true }) {
        guard !spaceKey.isEmpty,
              !inFlightKeys.contains(spaceKey),
              Self.hasScreenCaptureAccess,
              let captureRect = Self.captureRect(for: displayID)
        else { return }

        inFlightKeys.insert(spaceKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) { [weak self] in
            guard let self else { return }
            guard isCurrent() else {
                self.inFlightKeys.remove(spaceKey)
                return
            }

            self.ioQueue.async { [weak self] in
                guard let self else { return }
                let result = self.captureThumbnail(in: captureRect)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.inFlightKeys.remove(spaceKey)
                    guard let result, isCurrent() else { return }
                    self.thumbnails[spaceKey] = SpaceThumbnail(
                        image: NSImage(cgImage: result.image,
                                       size: NSSize(width: CGFloat(result.image.width),
                                                    height: CGFloat(result.image.height))),
                        capturedAt: result.capturedAt
                    )
                    self.ioQueue.async { [weak self] in
                        self?.write(pngData: result.pngData, for: spaceKey)
                    }
                }
            }
        }
    }

    func prune(validKeys: Set<String>) {
        thumbnails = thumbnails.filter { validKeys.contains($0.key) }
        guard lastPrunedKeys != validKeys else { return }
        lastPrunedKeys = validKeys

        let validFilenames = Set(validKeys.map { Self.filename(for: $0) })
        let directoryURL = self.directoryURL
        ioQueue.async {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else { return }

            for url in urls where url.pathExtension.lowercased() == "png" {
                guard !validFilenames.contains(url.lastPathComponent) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private struct CaptureResult {
        let image: CGImage
        let pngData: Data
        let capturedAt: Date
    }

    private func loadThumbnails(from directoryURL: URL) -> [String: SpaceThumbnail] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [:] }

        var loaded: [String: SpaceThumbnail] = [:]
        for url in urls where url.pathExtension.lowercased() == "png" {
            guard let key = Self.spaceKey(fromFilename: url.lastPathComponent),
                  let image = NSImage(contentsOf: url)
            else { continue }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            loaded[key] = SpaceThumbnail(
                image: image,
                capturedAt: values?.contentModificationDate ?? .distantPast
            )
        }
        return loaded
    }

    private func captureThumbnail(in rect: CGRect) -> CaptureResult? {
        guard CGPreflightScreenCaptureAccess(),
              let capturedImage = CGWindowListCreateImage(
                rect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.boundsIgnoreFraming, .bestResolution]
              ),
              let thumbnailImage = Self.downsample(
                image: capturedImage,
                maxPixelSize: maxPixelSize
              )
        else { return nil }

        let rep = NSBitmapImageRep(cgImage: thumbnailImage)
        guard let pngData = rep.representation(using: .png, properties: [:])
        else { return nil }

        return CaptureResult(
            image: thumbnailImage,
            pngData: pngData,
            capturedAt: Date()
        )
    }

    private func write(pngData: Data, for spaceKey: String) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try pngData.write(to: directoryURL.appendingPathComponent(
                Self.filename(for: spaceKey)
            ), options: .atomic)
        } catch {
            // Thumbnail persistence is opportunistic; the in-memory preview
            // still works for this run if disk writes fail.
        }
    }

    private static func downsample(image: CGImage,
                                   maxPixelSize: NSSize) -> CGImage? {
        let sourceSize = NSSize(width: CGFloat(image.width),
                                height: CGFloat(image.height))
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = max(
            maxPixelSize.width / sourceSize.width,
            maxPixelSize.height / sourceSize.height
        )
        let pixelWidth = max(1, Int(maxPixelSize.width.rounded()))
        let pixelHeight = max(1, Int(maxPixelSize.height.rounded()))
        let drawWidth = sourceSize.width * scale
        let drawHeight = sourceSize.height * scale
        let drawRect = CGRect(
            x: (CGFloat(pixelWidth) - drawWidth) / 2,
            y: (CGFloat(pixelHeight) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: drawRect)
        return context.makeImage()
    }

    private static func captureRect(for displayID: String) -> CGRect? {
        guard let directDisplayID = directDisplayID(for: displayID) else { return nil }
        return CGDisplayBounds(directDisplayID)
    }

    private static func directDisplayID(for displayID: String) -> CGDirectDisplayID? {
        if displayID == "Main" {
            return CGMainDisplayID()
        }
        if let parsed = UInt32(displayID) {
            return CGDirectDisplayID(parsed)
        }

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
            else { continue }

            let directDisplayID = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(directDisplayID)?
                .takeRetainedValue()
            else { continue }

            let uuidString = CFUUIDCreateString(nil, uuid) as String
            if uuidString.caseInsensitiveCompare(displayID) == .orderedSame {
                return directDisplayID
            }
        }
        return nil
    }

    private static func filename(for spaceKey: String) -> String {
        let encoded = spaceKey.addingPercentEncoding(
            withAllowedCharacters: allowedFilenameCharacters
        ) ?? UUID().uuidString
        return "\(encoded).png"
    }

    private static func spaceKey(fromFilename filename: String) -> String? {
        let basename = (filename as NSString).deletingPathExtension
        return basename.removingPercentEncoding
    }

    private static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    private static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
