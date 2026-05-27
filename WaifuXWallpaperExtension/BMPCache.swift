//  BMP snapshot cache for zero-gray transitions.

import AVFoundation
import CryptoKit
import Foundation
import ImageIO

func loadCachedSnapshotImage() -> CGImage? {
    guard let cacheDir = cacheDirectoryURL() else { return nil }
    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return nil }

    let bmpFiles = files.filter { $0.pathExtension.lowercased() == "bmp" }
    guard let newest = bmpFiles.max(by: {
        let d0 = (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
        let d1 = (try? fm.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
        return d0 < d1
    }) else { return nil }

    guard let data = try? Data(contentsOf: newest), data.count > 54 else { return nil }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
        width: Int(data[18]) | Int(data[19]) << 8,
        height: Int(data[22]) | Int(data[23]) << 8,
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        bytesPerRow: ((Int(data[18]) | Int(data[19]) << 8) * 3 + 3) & ~3,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

func writeBMPSnapshot(videoURL: URL, videoID: String?, displayPixelWidth: Int, displayPixelHeight: Int) async {
    guard let cacheDir = cacheDirectoryURL() else { return }
    let gained = cacheDir.startAccessingSecurityScopedResource()
    defer { if gained { cacheDir.stopAccessingSecurityScopedResource() } }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: displayPixelWidth, height: displayPixelHeight)

    let time = CMTime(seconds: 0.5, preferredTimescale: 600)
    guard let (image, _) = try? await generator.image(at: time) else { return }

    let hash = videoID.map { SHA256.hash(data: Data($0.utf8)).compactMap { String(format: "%02x", $0) }.joined() } ?? "unknown"
    let bmpURL = cacheDir.appendingPathComponent("\(hash).bmp")

    guard let mutableData = CFDataCreateMutable(nil, 0),
          let consumer = CGDataConsumer(data: mutableData),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = mutableData as Data? else { return }
    try? data.write(to: bmpURL)
}

private func cacheDirectoryURL() -> URL? {
    // Use shared container if available, fallback to documents
    if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
        let cacheDir = shared.appendingPathComponent("WallpaperCache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
}
