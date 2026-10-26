import Foundation

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}

private func checkWait(_ decision: SibionicsChineseRecoveryState.WatchdogDecision, _ expected: TimeInterval, _ message: String) {
    guard case .wait(let remaining) = decision else { fatalError(message) }
    check(abs(remaining - expected) < 0.001, message)
}

// Log regressions: the reconnect completed 6.659 and 7.737 seconds after
// the previous connection's request. Its first request must be immediate.
for reconnectDelay in [6.659, 7.737] {
    var state = SibionicsChineseRecoveryState()
    state.beginConnection(at: 100)
    check(state.canRequest(at: 100, requireStaleStream: false), "initial request blocked")
    state.didSendRequest(at: 100)
    check(!state.canRequest(at: 101, requireStaleStream: false), "same-connection throttle lost")
    let oldGeneration = state.connectionGeneration
    state.endConnection()
    check(!state.canRequest(at: 102, requireStaleStream: false), "request while disconnected")
    state.beginConnection(at: 100 + reconnectDelay)
    check(state.connectionGeneration != oldGeneration, "old callbacks can affect new connection")
    check(state.canRequest(at: 100 + reconnectDelay, requireStaleStream: false), "rapid reconnect still blocked by old request")
    state.didSendRequest(at: 100 + reconnectDelay)
    check(!state.canRequest(at: 100.1 + reconnectDelay, requireStaleStream: false), "duplicate startup request")
}

// A failed/not-ready BLE write is not recorded as a sent request.
var failedWrite = SibionicsChineseRecoveryState()
failedWrite.beginConnection(at: 0)
check(failedWrite.canRequest(at: 1, requireStaleStream: false), "request not eligible")
check(failedWrite.canRequest(at: 2, requireStaleStream: false), "unsent request consumed throttle")

// Both history immediately after the request and the live response at 9.681 s
// must cancel the pending disconnect. The old 10-second rearm throttle did not.
for responseDelay in [0.456, 1.041, 9.681] {
    var state = SibionicsChineseRecoveryState()
    state.beginConnection(at: 0)
    check(state.watchdogDecision(at: 80) == .request, "silent stream not recovered")
    state.didSendRequest(at: 80, isRecovery: true)
    checkWait(state.watchdogDecision(at: 85), 5, "recovery deadline wrong")
    state.didReceiveFrame(at: 80 + responseDelay)
    checkWait(state.watchdogDecision(at: 90.257), 69.743 + responseDelay, "valid response disconnected at old deadline")
}

var silent = SibionicsChineseRecoveryState()
silent.beginConnection(at: 0)
silent.didSendRequest(at: 80, isRecovery: true)
check(silent.watchdogDecision(at: 90) == .reconnect, "unanswered recovery must reconnect")
silent.endConnection()
check(silent.watchdogDecision(at: 200) == .inactive, "disconnected watchdog still active")

// A delayed watchdog waking hours later must consult current state, not its
// original timer phase. Fresh Bluetooth data always wins over an expired timer.
var delayed = SibionicsChineseRecoveryState()
delayed.beginConnection(at: 0)
check(delayed.watchdogDecision(at: 8_409) == .request, "suspended watchdog did not recover")
delayed.didSendRequest(at: 8_409, isRecovery: true)
delayed.didReceiveFrame(at: 8_410)
checkWait(delayed.watchdogDecision(at: 8_419), 71, "late timer ignored recovered stream")

// Heartbeat remains quiet during a healthy stream; no extra 30-second polling.
var healthy = SibionicsChineseRecoveryState()
healthy.beginConnection(at: 0)
healthy.didSendRequest(at: 0)
healthy.didReceiveFrame(at: 1)
check(!healthy.canRequest(at: 31, requireStaleStream: true), "healthy stream polled by heartbeat")
check(healthy.canRequest(at: 76, requireStaleStream: true), "stale heartbeat cannot recover")
healthy.didSendRequest(at: 76)
checkWait(healthy.watchdogDecision(at: 81), 5, "watchdog did not respect an in-flight heartbeat request")

print("sibionics_recovery_checks=\(checks) rapid_reconnect=ok history_response=ok stale_watchdog=ok heartbeat=ok")
