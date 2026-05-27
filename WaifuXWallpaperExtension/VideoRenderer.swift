//  Feeds video sample buffers to AVSampleBufferDisplayLayer
//  AVPlayerLayer doesn't work in remote CAContexts, so we render manually.

import AVFoundation
import CoreMedia

final class VideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?

    private var ptsOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero

    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    static func create(rootLayer: CALayer, videoURL: URL) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        rootLayer.addSublayer(displayLayer)
        return VideoRenderer(rootLayer: rootLayer, displayLayer: displayLayer, asset: asset, videoTrack: track)
    }

    private init(rootLayer: CALayer, displayLayer: AVSampleBufferDisplayLayer, asset: AVURLAsset, videoTrack: AVAssetTrack) {
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack
        self.stillFrameLayer = CALayer()
        stillFrameLayer.frame = rootLayer.bounds
        stillFrameLayer.contentsGravity = .resizeAspectFill
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        rootLayer.addSublayer(stillFrameLayer)

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase
    }

    // MARK: - Playback Control

    func start() {
        guard isRunning else { return }
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.recreatePlayback()
            guard self.currentReader != nil else { return }
            CMTimebaseSetRate(self.timebase, rate: self.isPaused ? 0.0 : 1.0)
            self.feedLoop()
        }
    }

    func stop() {
        isRunning = false
        isPaused = false
        currentPolicy = .full
        queue.async { [weak self] in
            guard let self else { return }
            self.renderer.stopRequestingMediaData()
            self.currentReader?.cancelReading()
            self.nextReader?.cancelReading()
            self.cancelRamp()
            self.cancelDeepPauseTimer()
            // 重置循环时间戳偏移，避免下次 start() 时累积错误
            self.ptsOffset = .zero
            self.lastEnqueuedEnd = .zero
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0
        if currentReader == nil {
            queue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.recreatePlayback()
                CMTimebaseSetRate(self.timebase, rate: 1.0)
            }
        } else {
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    // MARK: - Policy

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        cancelRamp()
        switch policy {
        case .paused:
            if animated { rampDown() } else { pause() }
        case .full, .reduced, .minimal:
            if animated, oldPolicy == .paused { rampUp() } else { resume() }
        }
    }

    // MARK: - Ramp

    private static let rampDuration: TimeInterval = 2.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    private func rampUp() {
        guard !isPaused else { resume(); return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { timer.cancel(); return }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = Self.easeInOut(progress)
            CMTimebaseSetRate(self.timebase, rate: Float64(eased))
            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
            }
        }
        self.rampTimer = timer
        timer.resume()
    }

    private func rampDown() {
        guard !isPaused else { return }
        let totalSteps = Int(Self.rampDuration / Self.rampStepInterval)
        var step = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { timer.cancel(); return }
            step += 1
            let progress = Double(step) / Double(totalSteps)
            let eased = 1.0 - Self.easeInOut(progress)
            CMTimebaseSetRate(self.timebase, rate: max(0, Float64(eased)))
            if step >= totalSteps {
                timer.cancel()
                self.rampTimer = nil
                self.pause()
            }
        }
        self.rampTimer = timer
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause

    private func scheduleDeepPause() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.isPaused else { return }
            self.currentReader?.cancelReading()
            self.nextReader?.cancelReading()
            self.currentReader = nil
            self.nextReader = nil
        }
        self.deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    // MARK: - Feed Loop

    private func feedLoop() {
        guard isRunning else { return }

        while isRunning, let output = currentOutput, renderer.isReadyForMoreMediaData {
            if let sample = output.copyNextSampleBuffer() {
                let adjusted = adjustedSampleBuffer(sample)
                renderer.enqueue(adjusted)
                let dur = CMSampleBufferGetDuration(adjusted)
                let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(adjusted), dur)
                if CMTimeCompare(end, lastEnqueuedEnd) > 0 {
                    lastEnqueuedEnd = end
                }
            } else {
                let readerStatus = currentReader?.status ?? .unknown
                if readerStatus == .completed || readerStatus == .reading {
                    // Loop boundary: gapless loop — no flush, no timebase reset.
                    // Advance ptsOffset so the next loop's sample PTS continues
                    // from where the previous loop ended.
                    if lastEnqueuedEnd.isValid && CMTimeCompare(lastEnqueuedEnd, ptsOffset) > 0 {
                        ptsOffset = lastEnqueuedEnd
                    }
                    lastEnqueuedEnd = .zero

                    // Swap to next reader (preloaded) or recreate synchronously
                    currentReader = nextReader
                    currentOutput = nextOutput
                    nextReader = nil
                    nextOutput = nil
                    if currentOutput == nil {
                        recreatePlayback()
                    }
                    // Continue loop — next iteration picks up new currentOutput
                    continue
                } else {
                    // Reader failed or was cancelled — attempt recovery
                    // 某些视频格式（HEVC/H.265、含 B 帧、变帧率等）可能导致
                    // AVAssetReader 中途 .failed，需要重建 reader 重新循环
                    currentReader?.cancelReading()
                    currentReader = nil
                    currentOutput = nil
                    recreatePlayback()
                    if currentOutput != nil {
                        continue
                    }
                    break
                }
            }
        }

        if isRunning {
            queue.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                self?.feedLoop()
            }
        }
    }

    private func recreatePlayback() {
        currentReader?.cancelReading()
        nextReader?.cancelReading()

        guard let reader = try? AVAssetReader(asset: asset) else {
            extLog("[VideoRenderer] ❌ AVAssetReader 创建失败: \(asset.url.lastPathComponent)")
            return
        }
        guard let track = asset.tracks(withMediaType: .video).first else {
            extLog("[VideoRenderer] ❌ 未找到视频轨道: \(asset.url.lastPathComponent)")
            reader.cancelReading()
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        // 验证 reader 是否成功开始读取
        guard reader.status == .reading else {
            extLog("[VideoRenderer] ❌ AVAssetReader.startReading 失败, status=\(reader.status.rawValue): \(asset.url.lastPathComponent)")
            reader.cancelReading()
            return
        }

        currentReader = reader
        currentOutput = output

        // ptsOffset 由循环边界维护，不能在重建 reader 时重置或再累加；
        // 否则第二轮开始的 sample 时间戳会倒退/重叠，renderer 会停止出帧。
        if !ptsOffset.isValid {
            ptsOffset = .zero
        }
        lastEnqueuedEnd = .zero
    }

    private func adjustedSampleBuffer(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let dur = CMSampleBufferGetDuration(sample)
        var timingInfo = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid
        )
        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo, sampleBufferOut: &adjusted)
        return adjusted ?? sample
    }

    // MARK: - Still Frame

    private func generateStillFrame() {
        let captureTime = CMTimebaseGetTime(timebase)
        let currentAsset = asset
        Task.detached(priority: .userInitiated) { [weak self] in
            let generator = AVAssetImageGenerator(asset: currentAsset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            guard let (cgImage, _) = try? await generator.image(at: captureTime) else { return }
            DispatchQueue.main.async {
                guard let self, self.isPaused else { return }
                self.stillFrameLayer.contents = cgImage
                self.stillFrameLayer.opacity = 1
            }
        }
    }
}
