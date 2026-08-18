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
    private let sensorMacAddress: [UInt8]?
    private let defaults: UserDefaults
    private let stateLock = NSLock()
    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryBlueToothTransmitter)

    private var algorithm: SibionicsV115GAlgorithm?
    private var algorithmLoadFailed = false
    private var receiveBuffer = Data()
    private var nextIndex: Int
    private var pollingTimer: Timer?
    private var didAnnounceSensor = false
    private var didLogAdvertisement = false

    private static let deviceInformationServiceUUID = CBUUID(string: "180A")
    private static let readableDeviceInformationUUIDs: Set<CBUUID> = [
        CBUUID(string: "2A23"), // System ID
        CBUUID(string: "2A24"), // Model Number String
        CBUUID(string: "2A25"), // Serial Number String
        CBUUID(string: "2A26")  // Firmware Revision String
    ]

    private var persistenceSuffix: String { shortCode.uppercased() }
    private var checkpointKey: String { "sibionics.v115g.checkpoint.\(persistenceSuffix)" }

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
        self.shortCode = resolvedShortCode
        self.sensitivity = parsedCode.flatMap { SibionicsChineseSensitivity.decode($0) }
        self.sensorMacAddress = SibionicsChineseIdentity.macAddress(from: sensorCode)
        self.cgmTransmitterDelegate = cgmTransmitterDelegate
        self.defaults = defaults
        let savedCheckpoint = defaults.data(forKey: "sibionics.v115g.checkpoint.\(resolvedShortCode)")
            .flatMap { try? JSONDecoder().decode(AlgorithmCheckpoint.self, from: $0) }
        self.nextIndex = max(savedCheckpoint?.nextIndex ?? 1, 1)

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
        startPolling()
        requestNewReading()
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
        receiveBuffer.append(value)
        drainReceiveBuffer()
    }

    override func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        stopPolling()
        receiveBuffer.removeAll(keepingCapacity: true)
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    override func prepareForRelease() {
        stopPolling()
        super.prepareForRelease()
    }

    deinit {
        stopPolling()
    }

    func requestNewReading() {
        stateLock.lock()
        let requestedIndex = nextIndex
        stateLock.unlock()
        _ = writeDataToPeripheral(
            data: SibionicsChineseProtocol.dataRequest(nextIndex: requestedIndex, macAddress: sensorMacAddress),
            type: .withResponse
        )
    }

    func cgmTransmitterType() -> CGMTransmitterType { .sibionicsChinese }
    func getCBUUID_Service() -> String { SibionicsChineseProtocol.serviceUUID }
    func getCBUUID_Receive() -> String { SibionicsChineseProtocol.notifyUUID }
    func isWebOOPEnabled() -> Bool { true }
    func nonWebOOPAllowed() -> Bool { false }
    func maxSensorAgeInDays() -> Double? { 14 }
    func needsSensorStartTime() -> Bool { false }

    private func startPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pollingTimer?.invalidate()
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.requestNewReading()
            }
        }
    }

    private func stopPolling() {
        // Do not create a weak reference to `self` here. This method is also
        // called from deinit, where objc_initWeak aborts because the object is
        // already being destroyed. Capture only the timer for deferred
        // invalidation so teardown never retains or weak-registers `self`.
        let timer = pollingTimer
        pollingTimer = nil
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
            process(entries: entries, receivedAt: Date())
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

    private func process(entries: [SibionicsChineseProtocol.Entry], receivedAt: Date) {
        guard !entries.isEmpty, ensureAlgorithm(), let algorithm = algorithm else { return }
        var output: [GlucoseData] = []
        var newestIndex = 0
        var sensorStartDate: Date?

        for entry in entries.sorted(by: { $0.index < $1.index }) {
            stateLock.lock()
            let expectedIndex = nextIndex
            stateLock.unlock()

            if entry.index <= 1, entry.isLive, expectedIndex > 2 {
                resetForNewSensor()
            }

            stateLock.lock()
            let currentExpected = nextIndex
            stateLock.unlock()
            if entry.index < currentExpected { continue }
            if entry.index > currentExpected {
                trace("SIBIONICS Chinese: exact algorithm gap, expected %{public}d received %{public}d", log: log, category: ConstantsLog.categoryBlueToothTransmitter, type: .error, currentExpected, entry.index)
                resetForHistoryRebuild()
                requestNewReading()
                return
            }

            guard entry.rawMmol.isFinite, entry.rawMmol > 0,
                  let displayMmol = algorithm.process(
                    rawMmol: entry.rawMmol,
                    temperatureC: entry.temperatureC,
                    index: entry.index,
                    live: entry.isLive
                  ) else {
                trace("SIBIONICS Chinese: algorithm rejected index %{public}d", log: log, category: ConstantsLog.categoryBlueToothTransmitter, type: .error, entry.index)
                return
            }

            let eventDate = entry.eventDate(receivedAt: receivedAt)
            let glucoseMgdl = displayMmol * 18.0
            guard glucoseMgdl.isFinite, glucoseMgdl > 0, glucoseMgdl <= 630 else { return }
            output.append(GlucoseData(timeStamp: eventDate, glucoseLevelRaw: glucoseMgdl))
            newestIndex = max(newestIndex, entry.index)
            sensorStartDate = eventDate.addingTimeInterval(TimeInterval(-entry.index * 60))

            stateLock.lock()
            nextIndex = entry.index + 1
            stateLock.unlock()
        }

        persistAlgorithmCheckpoint()
        guard !output.isEmpty else { return }
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
    }

    private func persistAlgorithmCheckpoint() {
        guard let snapshot = algorithm?.snapshot() else { return }
        stateLock.lock()
        let savedNextIndex = nextIndex
        stateLock.unlock()
        let checkpoint = AlgorithmCheckpoint(nextIndex: savedNextIndex, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        defaults.set(data, forKey: checkpointKey)
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
        stateLock.unlock()
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
