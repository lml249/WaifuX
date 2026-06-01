//  IOSurface snapshot creation for WallpaperAgent.

import AVFoundation
import CoreMedia
@preconcurrency import IOSurface

func createSnapshotViaRuntime(currentTime: CMTime? = nil) async -> AnyObject? {
    if let ioSurfaceSnapshot = WallpaperState.shared.anyIOSurfaceRenderer()?.makeSnapshotXPC() {
        extLog("  [Snapshot] Created WallpaperSnapshotXPC from active IOSurface")
        return ioSurfaceSnapshot
    }

    guard let videoURL = findVideoURL() else {
        extLog("  [Snapshot] No video file found")
        return nil
    }
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let requestTime: CMTime
    if let currentTime, currentTime.isValid, currentTime.seconds > 0 {
        requestTime = currentTime
    } else {
        do {
            let duration = try await asset.load(.duration)
            if duration.isValid, duration.seconds > 0 {
                let randomOffset = Double.random(in: 0 ..< duration.seconds)
                requestTime = CMTime(seconds: randomOffset, preferredTimescale: duration.timescale)
            } else {
                requestTime = .zero
            }
        } catch {
            requestTime = .zero
        }
    }

    let image: CGImage
    do {
        let result = try await generator.image(at: requestTime)
        image = result.image
    } catch {
        extLog("  [Snapshot] Failed to get video frame: \(error)")
        return nil
    }
    guard let snapshotXPC = renderSnapshotToIOSurface(image: image) else { return nil }
    extLog("  [Snapshot] Created WallpaperSnapshotXPC \(image.width)x\(image.height)")
    return snapshotXPC
}

private func renderSnapshotToIOSurface(image: CGImage) -> AnyObject? {
    let width = image.width
    let height = image.height
    let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: surfaceProps) else {
        extLog("  [Snapshot] Failed to create IOSurface")
        return nil
    }
    surface.lock(options: [], seed: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(
        data: surface.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    surface.unlock(options: [], seed: nil)

    guard let snapshotClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotClass, 0) else {
        extLog("  [Snapshot] Failed to create WallpaperSnapshotXPC")
        return nil
    }

    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    // The real class has a single `rawValue` ivar at offset 8 containing
    // a WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
    instancePtr.advanced(by: 8).storeBytes(of: surfaceRef, as: UnsafeMutableRawPointer.self)
    return instance as AnyObject
}
