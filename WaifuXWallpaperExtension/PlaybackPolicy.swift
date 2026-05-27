//  Central decision-maker for wallpaper playback behavior.

import Foundation

enum PlaybackPolicy: Int, Sendable, Comparable {
    case full = 0
    case reduced = 1
    case minimal = 2
    case paused = 3

    static func < (lhs: PlaybackPolicy, rhs: PlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int
    ) -> PlaybackPolicy {
        if userPaused { return .paused }
        if activityState == "suspended" { return .paused }
        if presentationMode == "idle" { return .paused }

        let onDesktop = presentationMode == "active"
        if onDesktop && alwaysPauseDesktop { return .paused }
        if onDesktop && pauseWhenOccluded && desktopOccluded { return .paused }

        switch thermalState {
        case .critical, .serious:
            return .paused
        case .fair:
            if isOnBattery && batteryLevel < 20 { return .minimal }
            return .reduced
        default:
            break
        }

        if isOnBattery && batteryLevel < 10 { return .minimal }
        return .full
    }
}
