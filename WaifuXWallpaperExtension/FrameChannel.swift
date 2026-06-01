//  持续帧通道 — 从 App 接收实时帧事件
//
//  通过独立的 Unix Socket 连接接收 App 推送的 frame_ready 事件。
//  连接保持打开，App 在每帧可用时写入二进制帧事件包。
//
//  帧事件包格式（二进制，共 25 字节）：
//    [0]     UInt8  = 0x01 (frame_ready)
//    [1-4]   UInt32 (LE) = displayID
//    [5-8]   UInt32 (LE) = IOSurfaceID
//    [9-16]  UInt64 (LE) = PTS 的 value
//    [17-20] UInt32 (LE) = PTS 的 timescale
//    [21-24] UInt32 (LE) = duration 的 value

import CoreMedia
import Foundation
import os

/// 帧通道客户端 — 运行在扩展中
final class FrameChannel: @unchecked Sendable {
    static let shared = FrameChannel()

    private var sock: Int32 = -1
    private let queue = DispatchQueue(label: "frame-channel", qos: .userInitiated)
    typealias Callback = @Sendable (IOSurfaceID, CMTime, CMTime) -> Void
    private var callbacks: [UInt32: Callback] = [:]
    private let cbLock = OSAllocatedUnfairLock(initialState: [UInt32: Callback]())
    private var hasLoggedConnection = false
    private var hasLoggedFirstFrame = false
    private var missingCallbackLogCount = 0

    private init() {}

    /// 注册帧回调（由 IOSurfaceFrameRenderer 调用）
    func registerCallback(displayID: UInt32, callback: @escaping Callback) {
        cbLock.withLock { $0[displayID] = callback }
    }

    /// 移除回调
    func unregisterCallback(displayID: UInt32) {
        cbLock.withLock { $0[displayID] = nil }
    }

    /// 打开持续帧通道，开始接收帧事件
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            var backoffMs = 100  // 初始 100ms
            let maxBackoffMs = 5000  // 最大 5s
            while true {
                let connected = connectAndReceive()
                if connected {
                    // 连接成功后重置退避
                    backoffMs = 100
                }
                // 指数退避：100ms → 200ms → 400ms → ... → 5s
                let delay = Double(min(backoffMs, maxBackoffMs)) / 1000.0
                Thread.sleep(forTimeInterval: delay)
                backoffMs = min(backoffMs * 2, maxBackoffMs)
            }
        }
    }

    /// 连接并持续读取帧事件；连接断开后返回，由调用者决定何时重连。
    private func connectAndReceive() -> Bool {
        guard let socketPath = socketPath() else { return false }

        sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock); sock = -1 }

        // 连接
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            Darwin.strncpy(UnsafeMutablePointer<CChar>(&addr.sun_path.0), src, MemoryLayout.size(ofValue: addr.sun_path))
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard Darwin.connect(sock, UnsafeRawPointer(&addr).assumingMemoryBound(to: sockaddr.self), len) == 0 else {
            return false
        }
        if !hasLoggedConnection {
            hasLoggedConnection = true
            extLog("[FrameChannel] 已连接帧通道 socket")
        }

        // 发送 subscribe 请求（包含 \0 结尾，确保服务端 String(cString:) 安全）
        let subMsg = "subscribe_frames"
        var msgLen = UInt32(subMsg.utf8.count + 1).bigEndian
        write(sock, &msgLen, 4)
        subMsg.withCString { write(sock, $0, subMsg.utf8.count + 1) }

        // 避免连接断开时收到 SIGPIPE 导致崩溃
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // 持续读取帧事件包
        var header: UInt8 = 0
        while read(sock, &header, 1) == 1 {
            guard header == 0x01 else { continue } // frame_ready

            var displayID: UInt32 = 0
            var surfaceID: UInt32 = 0
            var ptsVal: UInt64 = 0
            var ptsScale: UInt32 = 0
            var durVal: UInt32 = 0

            guard read(sock, &displayID, 4) == 4,
                  read(sock, &surfaceID, 4) == 4,
                  read(sock, &ptsVal, 8) == 8,
                  read(sock, &ptsScale, 4) == 4,
                  read(sock, &durVal, 4) == 4 else { break }

            let display = UInt32(littleEndian: displayID)
            let surf = UInt32(littleEndian: surfaceID)
            let pts = CMTime(value: CMTimeValue(UInt64(littleEndian: ptsVal)),
                            timescale: CMTimeScale(UInt32(littleEndian: ptsScale)))
            let dur = CMTime(value: CMTimeValue(UInt32(littleEndian: durVal)),
                            timescale: CMTimeScale(600))

            let cb = cbLock.withLock { $0[display] }
            if let cb {
                if !hasLoggedFirstFrame {
                    hasLoggedFirstFrame = true
                    extLog("[FrameChannel] 收到首个 frame_ready display=\(display) surface=\(surf) pts=\(pts.seconds)")
                }
                cb(surf, pts, dur)
            } else if missingCallbackLogCount < 5 {
                missingCallbackLogCount += 1
                extLog("[FrameChannel] ⚠️ 收到 display=\(display) 的帧但没有 callback surface=\(surf)")
            }
        }

        return false
    }

    private func socketPath() -> String? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")?
            .appendingPathComponent("socket/extension.ipc")
            .path
    }
}
