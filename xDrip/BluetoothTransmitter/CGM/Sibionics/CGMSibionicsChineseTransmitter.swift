import CoreBluetooth
import Foundation
import os

/// Direct BLE support for the Chinese SIBIONICS GS1 (AA55 protocol, v1.1.5G).
/// EU/V120/SIBIONICS 2 authentication is intentionally not implemented here.
final class CGMSibionicsChineseTransmitter: BluetoothTransmitter, CGMTransmitter {
    private struct AlgorithmCheckpoint: Codable {
        let nextIndex: Int
        let snapshot: String
    }

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?
    private let shortCode: String
    private let sensitivity: Double?
    private var sensorMacAddress: [UInt8]?
    private let defaults: UserDefaults
    private let stateLock = NSLock()
    private let processingQueue = DispatchQueue(label: "xdrip.sibionics.v115g.receiver", qos: .utility)
    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryBlueToothTransmitter)

    private var algorithm: SibionicsV115GAlgorithm?
    private var algorithmLoadFailed = false
    private var receiveBuffer = Data()
    private var nextIndex: Int
    private var lastCheckpointedNextIndex: Int
    private var pendingHistoricalOutput: [GlucoseData] = []
    // A first connection may replay up to 24 days of sensor history. The stock
    // Android path advances the algorithm through it without publishing every
    // history frame. Once a live checkpoint exists, retain bounded backfill for
    // ordinary short disconnects and publish it together with the next live row.
    private var shouldPreserveBackfill: Bool
    private var streamWatchdogTimer: Timer?
    private var lastValidDataFrameAt: Date?
    private var lastReadingRequestAt: Date?
    private var lastWatchdogArmAt: Date?
    private var pendingGapRecoveryIndex: Int?
    private var didAnnounceSensor = false
    private var didLogAdvertisement = false
    private var didLogWaitingForMacAddress = false

    private static let deviceInformationServiceUUID = CBUUID(string: "180A")
    private static let expectedLiveInterval: TimeInterval = 60
    private static let streamWatchdogGrace: TimeInterval = 20
    private static let recoveryResponseTimeout: TimeInterval = 10
    private static let heartbeatRecoveryThreshold: TimeInterval = 75
    private static let minimumRequestSpacing: TimeInterval = 10
    private static let minimumWatchdogRearmInterval: TimeInterval = 10
    private static let historicalCheckpointInterval = 500
    private static let maximumPreservedBackfillCount = 24 * 60
    private static let readableDeviceInformationUUIDs: Set<CBUUID> = [
        CBUUID(string: "2A23"), // System ID
        CBUUID(string: "2A24"), // Model Number String
        CBUUID(string: "2A25"), // Serial Number String
        CBUUID(string: "2A26")  // Firmware Revision String
    ]

    private var persistenceSuffix: String { shortCode.uppercased() }
    private var checkpointKey: String { "sibionics.v115g.checkpoint.\(persistenceSuffix)" }
    private var macAddressKey: String { "sibionics.v115g.mac.\(persistenceSuffix)" }

    init(
        address: String?,
        name: String?,
        sensorCode: String,
        bluetoothTransmitterDelegate: BluetoothTransmitterDelegate,
        cgmTransmitterDelegate: CGMTransmitterDelegate,
        defaults: UserDefaults = .standard
    ) {
        let parsedCode = SibionicsChineseIdentity.shortCode(from: sensorCode)
        let resolvedShortCode = parsedCode ?? sensorCode.uppercased().filter { $0.isLetter || $0.isNumber }
        let persistedMacAddress = defaults.data(forKey: "sibionics.v115g.mac.\(resolvedShortCode.uppercased())")
            .map(Array.init)
            .flatMap { Self.isValidMacAddress($0) ? $0 : nil }
        self.shortCode = resolvedShortCode
        self.sensitivity = parsedCode.flatMap { SibionicsChineseSensitivity.decode($0) }
        self.sensorMacAddress = SibionicsChineseIdentity.macAddress(from: sensorCode) ?? persistedMacAddress
        self.cgmTransmitterDelegate = cgmTransmitterDelegate
        self.defaults = defaults
        let savedCheckpoint = defaults.data(forKey: "sibionics.v115g.checkpoint.\(resolvedShortCode)")
            .flatMap { try? JSONDecoder().decode(AlgorithmCheckpoint.self, from: $0) }
        let restoredNextIndex = max(savedCheckpoint?.nextIndex ?? 1, 1)
        self.nextIndex = restoredNextIndex
        self.lastCheckpointedNextIndex = restoredNextIndex
        self.shouldPreserveBackfill = savedCheckpoint != nil && restoredNextIndex > 1

        let addressAndName: BluetoothTransmitter.DeviceAddressAndName
        if let address = address {
            addressAndName = .alreadyConnectedBefore(address: address, name: name)
        } else {
            // The first four characters of the QR-derived connection code are
            // the suffix of the advertised BLE name (for example 9MAE in
            // LT26049MAE). This identifies the intended sensor without needing
            // Android's BLE address and avoids connecting to another nearby GS1.
            addressAndName = .notYetConnected(expectedName: String(resolvedShortCode.prefix(4)))
        }

        super.init(
            addressAndName: addressAndName,
            CBUUID_Advertisement: SibionicsChineseProtocol.serviceUUID,
            servicesCBUUIDs: [
                CBUUID(string: SibionicsChineseProtocol.serviceUUID),
                Self.deviceInformationServiceUUID
            ],
            CBUUID_ReceiveCharacteristic: SibionicsChineseProtocol.notifyUUID,
            CBUUID_WriteCharacteristic: SibionicsChineseProtocol.writeUUID,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )
    }

    override func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        logAdvertisementOnce(peripheral: peripheral, advertisementData: advertisementData)
        super.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        guard error == nil,
              service.uuid == Self.deviceInformationServiceUUID,
              let characteristics = service.characteristics else { return }
        for characteristic in characteristics
        where Self.readableDeviceInformationUUIDs.contains(characteristic.uuid)
            && characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
        guard error == nil,
              characteristic.uuid == CBUUID(string: SibionicsChineseProtocol.notifyUUID),
              characteristic.isNotifying else { return }
        requestNewReading()
        armStreamWatchdog(
            after: Self.expectedLiveInterval + Self.streamWatchdogGrace,
            recoveryRequestAlreadySent: false
        )
    }

    override func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
        if Self.readableDeviceInformationUUIDs.contains(characteristic.uuid) {
            guard error == nil, let value = characteristic.value else { return }
            let text = String(data: value, encoding: .utf8) ?? "<binary>"
            trace(
                "SIBIONICS Chinese Device Information %{public}@ hex=%{public}@ text=%{public}@",
                log: log,
                category: ConstantsLog.categoryBlueToothTransmitter,
                type: .info,
                characteristic.uuid.uuidString,
                value.hexEncodedString(),
                text
            )
            if characteristic.uuid == CBUUID(string: "2A25") {
                updateMacAddress(fromSerialNumberValue: value)
            }
            return
        }
        guard error == nil,
              characteristic.uuid == CBUUID(string: SibionicsChineseProtocol.notifyUUID),
              let value = characteristic.value,
              !value.isEmpty else { return }
        if value.count >= 3,
           value[value.startIndex] == 0xaa,
           value[value.startIndex + 1] == 0x55,
           value[value.startIndex + 2] == 0x07 {
            // The Chinese sensor may echo either three bytes or the complete
            // request; it is an acknowledgement, never a data fragment.
            return
        }
        // A sensor with substantial history can send several ten-sample frames
        // per second. Keep JavaScriptCore processing and frame assembly away
        // from Core Bluetooth's main callback queue so the UI stays responsive.
        let chunk = value
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.receiveBuffer.append(chunk)
            self.drainReceiveBuffer()
        }
    }

    override func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        stopStreamWatchdog()
        stateLock.lock()
        pendingGapRecoveryIndex = nil
        stateLock.unlock()
        processingQueue.async { [weak self] in
            self?.receiveBuffer.removeAll(keepingCapacity: true)
        }
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func prepareForRelease() {
        stopStreamWatchdog()
        super.prepareForRelease()
    }

    deinit {
        stopStreamWatchdog()
    }

    func requestNewReading() {
        requestNewReading(requireStaleStream: false)
    }

    /// Heartbeat devices can wake xDrip every 30 seconds. They are useful for
    /// recovering a suspended stream, but must not turn a healthy push stream
    /// into continuous polling.
    func requestNewReadingIfStale() {
        requestNewReading(requireStaleStream: true)
    }

    private func requestNewReading(requireStaleStream: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.requestNewReading(requireStaleStream: requireStaleStream)
            }
            return
        }

        let now = Date()
        stateLock.lock()
        let requestedIndex = nextIndex
        let macAddress = sensorMacAddress
        let streamIsStale = lastValidDataFrameAt.map {
            now.timeIntervalSince($0) >= Self.heartbeatRecoveryThreshold
        } ?? true
        let requestSpacingElapsed = lastReadingRequestAt.map {
            now.timeIntervalSince($0) >= Self.minimumRequestSpacing
        } ?? true
        let shouldLogWaiting = macAddress == nil && !didLogWaitingForMacAddress
        if shouldLogWaiting {
            didLogWaitingForMacAddress = true
        }
        let shouldRequest = requestSpacingElapsed && (!requireStaleStream || streamIsStale)
        if shouldRequest, macAddress != nil {
            lastReadingRequestAt = now
        }
        stateLock.unlock()

        guard let macAddress = macAddress else {
            if shouldLogWaiting {
                trace(
                    "SIBIONICS Chinese: waiting for the sensor MAC in Device Information 2A25",
                    log: log,
                    category: ConstantsLog.categoryBlueToothTransmitter,
                    type: .info
                )
            }
            return
        }
        guard shouldRequest else { return }
        _ = writeDataToPeripheral(
            data: SibionicsChineseProtocol.dataRequest(nextIndex: requestedIndex, macAddress: macAddress),
            type: .withResponse
        )
    }

    func cgmTransmitterType() -> CGMTransmitterType { .sibionicsChinese }
    func getCBUUID_Service() -> String { SibionicsChineseProtocol.serviceUUID }
    func getCBUUID_Receive() -> String { SibionicsChineseProtocol.notifyUUID }
    func isWebOOPEnabled() -> Bool { true }
    func nonWebOOPAllowed() -> Bool { false }
    // Chinese GS1 produces usable one-minute rows immediately. Do not apply
    // xDrip's generic Libre warm-up gate to this transmitter.
    func sensorWarmupDurationInMinutes() -> Double? { 0 }
    // The rated Chinese GS1 lifetime is 14 days, but its observed extended
    // AA55 operating window is approximately 24 days (572 h minus 19 min).
    // xDrip uses this value for the lifetime/progress display; it must reflect
    // the usable Chinese window rather than showing the sensor as expired.
    func maxSensorAgeInDays() -> Double? { 24 }
    func needsSensorStartTime() -> Bool { false }

    private func armStreamWatchdog(after interval: TimeInterval, recoveryRequestAlreadySent: Bool) {
        let now = Date()
        stateLock.lock()
        lastWatchdogArmAt = now
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.streamWatchdogTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.streamWatchdogExpired(recoveryRequestAlreadySent: recoveryRequestAlreadySent)
            }
            timer.tolerance = 1
            self.streamWatchdogTimer = timer
        }
    }

    private func streamWatchdogExpired(recoveryRequestAlreadySent: Bool) {
        streamWatchdogTimer = nil
        if recoveryRequestAlreadySent {
            trace(
                "SIBIONICS Chinese: no data after recovery request; reconnecting immediately",
                log: log,
                category: ConstantsLog.categoryBlueToothTransmitter,
                type: .error
            )
            disconnect()
            return
        }

        trace(
            "SIBIONICS Chinese: live stream missed its expected interval; requesting backfill",
            log: log,
            category: ConstantsLog.categoryBlueToothTransmitter,
            type: .info
        )
        requestNewReading()
        armStreamWatchdog(after: Self.recoveryResponseTimeout, recoveryRequestAlreadySent: true)
    }

    private func noteValidDataFrame() {
        let now = Date()
        stateLock.lock()
        lastValidDataFrameAt = now
        let shouldRearm = lastWatchdogArmAt.map {
            now.timeIntervalSince($0) >= Self.minimumWatchdogRearmInterval
        } ?? true
        stateLock.unlock()
        guard shouldRearm else { return }
        armStreamWatchdog(
            after: Self.expectedLiveInterval + Self.streamWatchdogGrace,
            recoveryRequestAlreadySent: false
        )
    }

    private func stopStreamWatchdog() {
        // Do not create a weak reference to `self` here. This method is also
        // called from deinit, where objc_initWeak aborts because the object is
        // already being destroyed. Capture only the timer for deferred
        // invalidation so teardown never retains or weak-registers `self`.
        let timer = streamWatchdogTimer
        streamWatchdogTimer = nil
        if Thread.isMainThread {
            timer?.invalidate()
        } else {
            DispatchQueue.main.async {
                timer?.invalidate()
            }
        }
    }

    private func logAdvertisementOnce(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        guard !didLogAdvertisement else { return }
        didLogAdvertisement = true

        var fields = ["peripheralUUID=\(peripheral.identifier.uuidString)"]
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            fields.append("localName=\(localName)")
        }
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            fields.append("manufacturerData=\(manufacturerData.hexEncodedString())")
        }
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            fields.append("serviceUUIDs=\(serviceUUIDs.map(\.uuidString).sorted().joined(separator: ","))")
        }
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            let values = serviceData
                .map { "\($0.key.uuidString)=\($0.value.hexEncodedString())" }
                .sorted()
                .joined(separator: ",")
            fields.append("serviceData=\(values)")
        }
        trace(
            "SIBIONICS Chinese advertisement: %{public}@",
            log: log,
            category: ConstantsLog.categoryBlueToothTransmitter,
            type: .info,
            fields.joined(separator: " ")
        )
    }

    /// The Chinese GS1 exposes its six-byte BLE address as the value of the
    /// Device Information Serial Number characteristic (2A25). The on-air
    /// AA5507 request uses those bytes in the opposite order, as confirmed by
    /// captures from the same sensor on Android and iOS.
    private func updateMacAddress(fromSerialNumberValue value: Data) {
        let serialBytes = [UInt8](value)
        guard serialBytes.count == 6 else { return }
        let discoveredMacAddress = Array(serialBytes.reversed())
        guard Self.isValidMacAddress(discoveredMacAddress) else { return }

        stateLock.lock()
        let previouslyMissing = sensorMacAddress == nil
        let didChange = sensorMacAddress != discoveredMacAddress
        sensorMacAddress = discoveredMacAddress
        didLogWaitingForMacAddress = false
        stateLock.unlock()

        defaults.set(Data(discoveredMacAddress), forKey: macAddressKey)
        if didChange {
            trace(
                "SIBIONICS Chinese: obtained sensor MAC %{public}@ from Device Information 2A25",
                log: log,
                category: ConstantsLog.categoryBlueToothTransmitter,
                type: .info,
                discoveredMacAddress.map { String(format: "%02X", $0) }.joined(separator: ":")
            )
        }
        if previouslyMissing || didChange {
            requestNewReading()
        }
    }

    private static func isValidMacAddress(_ address: [UInt8]) -> Bool {
        address.count == 6
            && !address.allSatisfy { $0 == 0x00 }
            && !address.allSatisfy { $0 == 0xff }
    }

    private func drainReceiveBuffer() {
        while true {
            alignReceiveBuffer()
            guard receiveBuffer.count >= 3,
                  let frameLength = SibionicsChineseProtocol.expectedFrameLength(in: receiveBuffer),
                  receiveBuffer.count >= frameLength else { return }
            let frame = Data(receiveBuffer.prefix(frameLength))
            receiveBuffer.removeFirst(frameLength)

            // AA5507 is the sensor's echo/acknowledgement of our request.
            if frame.count >= 3, frame[frame.startIndex + 2] == 0x07 { continue }
            guard let entries = SibionicsChineseProtocol.parseDataFrame(frame) else {
                trace("SIBIONICS Chinese: rejected malformed/checksum frame", log: log, category: ConstantsLog.categoryBlueToothTransmitter, type: .error)
                continue
            }
            if process(entries: entries, receivedAt: Date()) {
                noteValidDataFrame()
            }
        }
    }

    private func alignReceiveBuffer() {
        while receiveBuffer.count >= 2 {
            if receiveBuffer[receiveBuffer.startIndex] == 0xaa,
               receiveBuffer[receiveBuffer.startIndex + 1] == 0x55 {
                guard receiveBuffer.count >= 3 else { return }
                if receiveBuffer[receiveBuffer.startIndex + 2] == 0x09 { return }
            }
            receiveBuffer.removeFirst()
        }
    }

    private func ensureAlgorithm() -> Bool {
        if algorithm != nil { return true }
        if algorithmLoadFailed { return false }
        guard let sensitivity = sensitivity else {
            algorithmLoadFailed = true
            reportAlgorithmError("The SIBIONICS sensor code is invalid; no glucose was calculated.")
            return false
        }
        do {
            let newAlgorithm = try SibionicsV115GAlgorithm(sensitivity: sensitivity)
            if nextIndex > 1 {
                guard let checkpoint = loadCheckpoint(),
                      checkpoint.nextIndex == nextIndex,
                      newAlgorithm.restore(snapshot: checkpoint.snapshot) else {
                    algorithm = newAlgorithm
                    resetForHistoryRebuild()
                    requestNewReading()
                    return false
                }
            }
            algorithm = newAlgorithm
            return true
        } catch {
            algorithmLoadFailed = true
            reportAlgorithmError(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    private func process(entries: [SibionicsChineseProtocol.Entry], receivedAt: Date) -> Bool {
        guard !entries.isEmpty, ensureAlgorithm(), var algorithm = algorithm else { return false }
        var output: [GlucoseData] = []
        var processedAnyEntry = false
        var processedLiveEntry = false
        var newestIndex = 0
        var sensorStartDate: Date?

        for entry in entries.sorted(by: { $0.index < $1.index }) {
            stateLock.lock()
            let expectedIndex = nextIndex
            stateLock.unlock()

            if entry.index <= 1, entry.isLive, expectedIndex > 2 {
                resetForNewSensor()
                guard let resetAlgorithm = self.algorithm else { return false }
                algorithm = resetAlgorithm
            }

            stateLock.lock()
            let currentExpected = nextIndex
            stateLock.unlock()
            if entry.index < currentExpected { continue }
            if entry.index > currentExpected {
                requestMissingIndexIfNeeded(expectedIndex: currentExpected, receivedIndex: entry.index)
                return false
            }

            guard entry.rawMmol.isFinite, entry.rawMmol > 0 else {
                trace(
                    "SIBIONICS Chinese: invalid raw glucose at index %{public}d",
                    log: log,
                    category: ConstantsLog.categoryBlueToothTransmitter,
                    type: .error,
                    entry.index
                )
                return false
            }

            let displayMmol: Double
            switch algorithm.process(
                    rawMmol: entry.rawMmol,
                    temperatureC: entry.temperatureC,
                    index: entry.index,
                    live: entry.isLive
            ) {
            case .output(let value):
                displayMmol = value
            case .failure(let reason):
                trace(
                    "SIBIONICS Chinese: algorithm failed at index %{public}d: %{public}@",
                    log: log,
                    category: ConstantsLog.categoryBlueToothTransmitter,
                    type: .error,
                    entry.index,
                    reason
                )
                return false
            }

            let eventDate = entry.eventDate(receivedAt: receivedAt)
            processedAnyEntry = true
            if entry.isLive {
                processedLiveEntry = true
            }

            if displayMmol > 0 {
                let glucose = GlucoseData(timeStamp: eventDate, glucoseLevelRaw: displayMmol * 18.0)
                if entry.isLive {
                    output.append(glucose)
                } else if shouldPreserveBackfill {
                    pendingHistoricalOutput.append(glucose)
                    if pendingHistoricalOutput.count > Self.maximumPreservedBackfillCount {
                        pendingHistoricalOutput.removeFirst(
                            pendingHistoricalOutput.count - Self.maximumPreservedBackfillCount
                        )
                    }
                }
            } else {
                // The managed adapter deliberately uses zero when a carried
                // correction would make a very low recovered row negative.
                // The algorithm state has still consumed this minute. Advance
                // the checkpoint without publishing a false 0 mg/dL reading.
                trace(
                    "SIBIONICS Chinese: consumed index %{public}d without a publishable glucose value",
                    log: log,
                    category: ConstantsLog.categoryBlueToothTransmitter,
                    type: .info,
                    entry.index
                )
            }
            newestIndex = max(newestIndex, entry.index)
            sensorStartDate = eventDate.addingTimeInterval(TimeInterval(-entry.index * 60))

            stateLock.lock()
            nextIndex = entry.index + 1
            if pendingGapRecoveryIndex == entry.index {
                pendingGapRecoveryIndex = nil
            }
            stateLock.unlock()
        }

        guard processedAnyEntry else { return false }
        // While preserving a short gap, keep the checkpoint at the last row
        // already handed to xDrip. If the app is interrupted before live data,
        // the gap will be replayed rather than silently skipped on next launch.
        if processedLiveEntry || !shouldPreserveBackfill {
            persistAlgorithmCheckpoint(force: processedLiveEntry)
        }
        guard !output.isEmpty else { return true }
        if !pendingHistoricalOutput.isEmpty {
            output.append(contentsOf: pendingHistoricalOutput)
            pendingHistoricalOutput.removeAll(keepingCapacity: true)
        }
        shouldPreserveBackfill = true
        output.sort { $0.timeStamp > $1.timeStamp }
        let sensorAge = TimeInterval(newestIndex * 60)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.didAnnounceSensor {
                self.didAnnounceSensor = true
                if self.shouldAnnounceSensor(startDate: sensorStartDate) {
                    self.cgmTransmitterDelegate?.newSensorDetected(sensorStartDate: sensorStartDate)
                }
            }
            var copy = output
            self.cgmTransmitterDelegate?.cgmTransmitterInfoReceived(
                glucoseData: &copy,
                transmitterBatteryInfo: nil,
                sensorAge: sensorAge
            )
        }
        return true
    }

    /// The algorithm is stateful, so a missing minute must be requested before
    /// processing later rows. Preserve the valid state we already have instead
    /// of restarting from index 1. A restart can replay tens of thousands of
    /// rows and, while live frames are still queued, repeatedly restart itself.
    private func requestMissingIndexIfNeeded(expectedIndex: Int, receivedIndex: Int) {
        stateLock.lock()
        let shouldStartRecovery = pendingGapRecoveryIndex != expectedIndex
        if shouldStartRecovery {
            pendingGapRecoveryIndex = expectedIndex
        }
        stateLock.unlock()

        guard shouldStartRecovery else { return }
        trace(
            "SIBIONICS Chinese: exact algorithm gap, expected %{public}d received %{public}d; requesting the missing row without resetting",
            log: log,
            category: ConstantsLog.categoryBlueToothTransmitter,
            type: .error,
            expectedIndex,
            receivedIndex
        )
        requestNewReading()

        // The first request can legitimately be inside the normal ten-second
        // write throttle. Retry once after it expires, but only if the expected
        // row has not arrived in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.minimumRequestSpacing) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let isStillMissing = self.pendingGapRecoveryIndex == expectedIndex
                && self.nextIndex == expectedIndex
            self.stateLock.unlock()
            guard isStillMissing else { return }
            self.requestNewReading()
        }
    }

    private func persistAlgorithmCheckpoint(force: Bool) {
        stateLock.lock()
        let savedNextIndex = nextIndex
        let checkpointDistance = savedNextIndex - lastCheckpointedNextIndex
        stateLock.unlock()
        guard force || checkpointDistance >= Self.historicalCheckpointInterval else { return }
        guard let snapshot = algorithm?.snapshot() else { return }
        let checkpoint = AlgorithmCheckpoint(nextIndex: savedNextIndex, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        defaults.set(data, forKey: checkpointKey)
        stateLock.lock()
        lastCheckpointedNextIndex = savedNextIndex
        stateLock.unlock()
    }

    private func loadCheckpoint() -> AlgorithmCheckpoint? {
        guard let data = defaults.data(forKey: checkpointKey) else { return nil }
        return try? JSONDecoder().decode(AlgorithmCheckpoint.self, from: data)
    }

    /// A transmitter object is recreated when xDrip starts. Do not turn that
    /// ordinary restore into a stop/start cycle for the already-active sensor.
    private func shouldAnnounceSensor(startDate: Date?) -> Bool {
        guard let startDate = startDate else { return false }
        guard let activeStartDate = defaults.activeSensorStartDate else { return true }
        return abs(activeStartDate.timeIntervalSince(startDate)) > 5 * 60
    }

    private func resetForNewSensor() {
        didAnnounceSensor = false
        resetForHistoryRebuild()
    }

    private func resetForHistoryRebuild() {
        defaults.removeObject(forKey: checkpointKey)
        stateLock.lock()
        nextIndex = 1
        lastCheckpointedNextIndex = 1
        pendingGapRecoveryIndex = nil
        stateLock.unlock()
        pendingHistoricalOutput.removeAll(keepingCapacity: true)
        shouldPreserveBackfill = false
        if let sensitivity = sensitivity {
            algorithm = try? SibionicsV115GAlgorithm(sensitivity: sensitivity)
        } else {
            algorithm = nil
        }
    }

    private func reportAlgorithmError(_ message: String) {
        trace("SIBIONICS Chinese algorithm unavailable: %{public}@", log: log, category: ConstantsLog.categoryBlueToothTransmitter, type: .error, message)
        DispatchQueue.main.async { [weak self] in
            self?.bluetoothTransmitterDelegate?.error(message: message)
        }
    }

}
