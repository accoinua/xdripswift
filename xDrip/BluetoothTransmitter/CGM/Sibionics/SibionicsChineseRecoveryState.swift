import Foundation

/// Timing decisions only; the transmitter owns this value on its Core Bluetooth
/// queue. Times are system uptime, independent of timezone or wall-clock changes.
struct SibionicsChineseRecoveryState {
    enum WatchdogDecision: Equatable {
        case inactive
        case wait(TimeInterval)
        case request
        case reconnect
    }

    static let liveTimeout: TimeInterval = 80
    static let recoveryTimeout: TimeInterval = 10
    static let staleThreshold: TimeInterval = 75
    static let minimumRequestSpacing: TimeInterval = 10

    private(set) var connectionGeneration: UInt64 = 0
    private var connectedAt: TimeInterval?
    private var lastFrameAt: TimeInterval?
    private var lastRequestAt: TimeInterval?
    private var recoveryRequestedAt: TimeInterval?

    mutating func beginConnection(at now: TimeInterval) {
        connectionGeneration &+= 1
        connectedAt = now
        lastFrameAt = nil
        lastRequestAt = nil
        recoveryRequestedAt = nil
    }

    mutating func endConnection() {
        connectionGeneration &+= 1
        connectedAt = nil
        lastFrameAt = nil
        lastRequestAt = nil
        recoveryRequestedAt = nil
    }

    func canRequest(at now: TimeInterval, requireStaleStream: Bool) -> Bool {
        guard connectedAt != nil else { return false }
        if let lastRequestAt, now - lastRequestAt < Self.minimumRequestSpacing {
            return false
        }
        if requireStaleStream, let lastFrameAt, now - lastFrameAt < Self.staleThreshold {
            return false
        }
        return true
    }

    /// Call only after the BLE write was accepted. A missing characteristic must
    /// not consume the request allowance for this connection.
    mutating func didSendRequest(at now: TimeInterval, isRecovery: Bool = false) {
        lastRequestAt = now
        if isRecovery {
            recoveryRequestedAt = now
        }
    }

    mutating func didReceiveFrame(at now: TimeInterval) {
        lastFrameAt = now
        // History is also a valid response. Do not cut off a working history
        // transfer while waiting for its next live minute.
        recoveryRequestedAt = nil
    }

    func watchdogDecision(at now: TimeInterval) -> WatchdogDecision {
        guard let connectedAt else { return .inactive }
        if let recoveryRequestedAt {
            let remaining = Self.recoveryTimeout - (now - recoveryRequestedAt)
            return remaining > 0 ? .wait(remaining) : .reconnect
        }
        let remaining = Self.liveTimeout - (now - (lastFrameAt ?? connectedAt))
        if remaining > 0 { return .wait(remaining) }
        if let lastRequestAt {
            let spacing = Self.minimumRequestSpacing - (now - lastRequestAt)
            if spacing > 0 { return .wait(spacing) }
        }
        return .request
    }
}
