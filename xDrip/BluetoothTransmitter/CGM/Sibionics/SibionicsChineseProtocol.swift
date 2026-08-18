import Foundation

enum SibionicsChineseProtocol {
    static let serviceUUID = "FF30"
    static let notifyUUID = "FF31"
    static let writeUUID = "FF32"

    struct Entry {
        let index: Int
        let rawTemperature: Int
        let rawImpedance: Int
        let rawGlucose: Int
        let status: Int
        let numberUnreceived: Int
        let addTimeSeconds: Int

        var temperatureC: Double { Double(rawTemperature) / 10.0 }
        var rawMmol: Double { Double(rawGlucose) / 10.0 }
        var isLive: Bool { numberUnreceived == 0 }

        func eventDate(receivedAt: Date) -> Date {
            let offset = min(addTimeSeconds - numberUnreceived * 60, 0)
            return receivedAt.addingTimeInterval(TimeInterval(offset))
        }
    }

    static func dataRequest(nextIndex: Int, macAddress: [UInt8]?) -> Data {
        var packet = [UInt8](repeating: 0, count: 20)
        let requestedIndex = min(max(nextIndex, 1), 0xffff)
        packet[0] = 0xaa
        packet[1] = 0x55
        packet[2] = 0x07
        packet[3] = UInt8(truncatingIfNeeded: requestedIndex)
        packet[4] = UInt8(truncatingIfNeeded: requestedIndex >> 8)
        // Juggluco puts the Android BLE address here in reverse byte order.
        // CoreBluetooth does not expose that address. Keep an optional manual
        // value for protocol research, but never require Android during normal
        // sensor setup. Until the native iOS identity source is confirmed, a
        // missing value deliberately remains zero rather than being guessed.
        if let macAddress = macAddress, macAddress.count == 6 {
            for index in 0..<6 {
                packet[5 + index] = macAddress[5 - index]
            }
        }
        packet[19] = checksum(packet.dropLast())
        return Data(packet)
    }

    static func parseDataFrame(_ frame: Data) -> [Entry]? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 5, bytes[0] == 0xaa, bytes[1] == 0x55, bytes[2] == 0x09 else {
            return nil
        }
        let count = Int(bytes[3])
        let expectedSize = 5 + count * 14
        guard bytes.count == expectedSize, bytes.last == checksum(bytes.dropLast()) else { return nil }
        return (0..<count).map { item in
            let offset = 4 + item * 14
            return Entry(
                index: u16be(bytes, offset),
                rawTemperature: u16be(bytes, offset + 2),
                rawImpedance: u16be(bytes, offset + 4),
                rawGlucose: u16be(bytes, offset + 6),
                status: u16be(bytes, offset + 8),
                numberUnreceived: u16be(bytes, offset + 10),
                addTimeSeconds: u16be(bytes, offset + 12)
            )
        }
    }

    static func expectedFrameLength(in buffer: Data) -> Int? {
        let bytes = [UInt8](buffer.prefix(4))
        guard bytes.count >= 3, bytes[0] == 0xaa, bytes[1] == 0x55 else { return nil }
        guard bytes[2] == 0x09, bytes.count == 4 else { return nil }
        return 5 + Int(bytes[3]) * 14
    }

    private static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return UInt8(0) &- sum
    }

    private static func u16be(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }
}

enum SibionicsChineseIdentity {
    static func shortCode(from input: String?) -> String? {
        guard let input = input else { return nil }
        let identity = input.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? input
        var framed = identity.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if framed.hasPrefix("]D2") { framed.removeFirst(3) }
        let payload = framed.filter { $0.isLetter || $0.isNumber || $0 == "\u{001D}" }
        let normalized = payload.filter { $0.isLetter || $0.isNumber }
        if normalized.count == 8, SibionicsChineseSensitivity.decode(String(normalized)) != nil {
            return String(normalized)
        }

        guard payload.contains("0697283164"), payload.count >= 50 else { return nil }
        let chars = Array(payload)
        let nativeName: String?
        if chars.count < 65 {
            let endLength = chars.count - 49
            let startLength = 16 - endLength
            guard endLength > 0, startLength >= 0, chars.count >= 49 + endLength,
                  chars.count >= 22 + startLength else { return nil }
            nativeName = String(
                Array(chars[22..<(22 + startLength)]) +
                Array(chars[49..<(49 + endLength)])
            )
        } else {
            let start = chars.count - 17
            nativeName = String(chars[start..<(start + 16)])
        }
        guard let compact = nativeName?.filter({ $0.isLetter || $0.isNumber }), compact.count == 16 else {
            return nil
        }
        let short = String(compact.suffix(11).prefix(8))
        return SibionicsChineseSensitivity.decode(short) == nil ? nil : short
    }

    /// Reads the explicit BLE address from `sensor-code|AA:BB:CC:DD:EE:FF`.
    /// We intentionally do not guess a MAC from GS1 digits or CoreBluetooth's
    /// peripheral UUID; neither is the Bluetooth device address.
    static func macAddress(from input: String?) -> [UInt8]? {
        guard let input = input,
              let separator = input.lastIndex(of: "|") else { return nil }
        let rawAddress = input[input.index(after: separator)...]
        let compact = rawAddress.filter { $0.isHexDigit }
        guard compact.count == 12 else { return nil }

        var result: [UInt8] = []
        result.reserveCapacity(6)
        var cursor = compact.startIndex
        for _ in 0..<6 {
            let end = compact.index(cursor, offsetBy: 2)
            guard let byte = UInt8(compact[cursor..<end], radix: 16) else { return nil }
            result.append(byte)
            cursor = end
        }
        return result
    }
}

enum SibionicsChineseSensitivity {
    static func decode(_ shortCode: String?) -> Double? {
        let normalized = shortCode?.uppercased().filter { $0.isLetter || $0.isNumber } ?? ""
        let token = String(normalized.suffix(4))
        guard token.count == 4 else { return nil }
        if token.allSatisfy(\.isNumber), let digits = Double(token) {
            return supported(digits / 1000.0)
        }
        if let digits = decodedDigits(token, base: "A") {
            if let result = supported(Double(digits) / 100.0) { return result }
        }
        if let digits = decodedDigits(token, base: "P") {
            return supported(Double(digits) / 100.0)
        }
        return nil
    }

    private static func supported(_ value: Double) -> Double? {
        value.isFinite && value >= 0.8 && value <= 2.5 ? value : nil
    }

    private static func decodedDigits(_ token: String, base: Character) -> Int? {
        let mapped = token.uppercased().map { character -> Character in
            if character == "K" { return "I" }
            if character == "I" { return "!" }
            return character
        }
        guard mapped.count == 4, let baseValue = base.asciiValue else { return nil }
        let t = mapped.compactMap(\.asciiValue).map(Int.init)
        guard t.count == 4 else { return nil }
        let baseInt = Int(baseValue)
        let out3 = (baseInt - t[3]) + 57
        var w9 = (t[3] - baseInt) + 48

        let w10: Int
        let out2: Int
        if t[2] >= baseInt {
            let w11 = t[2] - baseInt
            w10 = w11 + 48
            w9 = (9 - w11) + w9
            out2 = w9
        } else {
            let w11 = (t[2] <= (w9 & 0xff) ? 48 : 57)
            w10 = t[2]
            w9 = (w11 - t[2]) + w9
            out2 = w9
        }

        let out1: Int
        let w11b: Int
        var w10b = w10
        if t[1] >= baseInt {
            let w12 = t[1] - baseInt
            w11b = w12 + 48
            w10b = (9 - w12) + w10b
            out1 = w10b
        } else {
            let w12 = (t[1] <= (w10b & 0xff) ? 48 : 57) - t[1]
            w11b = t[1]
            w10b = w12 + w10b
            out1 = w10b
        }

        let out0: Int
        if t[0] >= baseInt {
            out0 = (baseInt - t[0]) + 9 + w11b
        } else {
            out0 = ((t[0] <= (w11b & 0xff) ? 48 : 57) - t[0]) + w11b
        }
        let checksum = ((out0 + out1 + out2 - 0x90) % 10 + 10) % 10
        guard out3 - 48 == checksum else { return nil }
        let result = [out0, out1, out2].compactMap { value -> UnicodeScalar? in
            UnicodeScalar(value)
        }.map { String(Character($0)) }.joined()
        return Int(result)
    }
}
