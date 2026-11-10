import Foundation
import IOKit.hid

/// The lighting protocol of EVision keyboards (VID 0x320F), the chip family
/// inside the Rampage Parvus. Protocol facts as documented by OpenRGB's
/// EVision controllers; this is an independent Swift implementation.
///
/// Every packet is 64 bytes on report 4:
///   [0] 0x04  [1..2] checksum of bytes 3...63 (little endian)
///   [3] command  [4] payload size  [5..6] offset (little endian)  [8...] payload
/// The keyboard answers each packet with an echo carrying any data read.
enum EVision {
    static let vendorID = 0x320F
    static let productID = 0x5055
    static let usagePage = 0xFF1C
    static let usage = 0x92
    static let reportID: UInt8 = 4
    static let packetSize = 64
    static let maxPayload = packetSize - 8

    enum Command: UInt8 {
        case begin = 0x01
        case end = 0x02
        case readCapabilities = 0x03   // newer firmware (v2) only
        case readConfig = 0x05         // v2
        case writeConfig = 0x06        // v1 "set parameter", v2 "write config"
        case dynamicColors = 0x12      // v2: live colours, not saved
    }

    enum Version: String {
        case v1 = "EVision v1"
        case v2 = "EVision v2"
    }

    /// The lighting settings shared by both versions.
    struct Lighting: Equatable, Codable {
        var mode: UInt8 = 0x06
        var brightness: UInt8 = 4    // 0 (off) ... 4
        var speed: UInt8 = 3         // 0 (fastest) ... 5 (slowest)
        var direction: UInt8 = 0
        var random = false
        var red: UInt8 = 255
        var green: UInt8 = 255
        var blue: UInt8 = 255
    }

    static func packet(_ command: UInt8, offset: Int = 0, size: Int = 0, payload: [UInt8] = []) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: packetSize)
        buffer[0] = reportID
        buffer[3] = command
        buffer[4] = UInt8(size)
        buffer[5] = UInt8(offset & 0xFF)
        buffer[6] = UInt8((offset >> 8) & 0xFF)
        for (index, byte) in payload.prefix(maxPayload).enumerated() {
            buffer[8 + index] = byte
        }
        var checksum: UInt16 = 0
        for byte in buffer[3...] { checksum &+= UInt16(byte) }
        buffer[1] = UInt8(checksum & 0xFF)
        buffer[2] = UInt8(checksum >> 8)
        return buffer
    }
}

/// One opened keyboard interface: sends packets and waits for the echo.
@MainActor
final class EVisionKeyboard {
    let device: IOHIDDevice
    private(set) var version: EVision.Version = .v1
    /// v2: number of LED slots in the dynamic colour map.
    private(set) var mapSize = 0

    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: EVision.packetSize)
    private var waiting: (command: UInt8, continuation: CheckedContinuation<[UInt8]?, Never>)?
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(device: IOHIDDevice) {
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, EVision.packetSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let keyboard = Unmanaged<EVisionKeyboard>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Some paths hand over the report without its ID byte.
            if bytes.count == EVision.packetSize - 1 { bytes.insert(UInt8(reportID), at: 0) }
            MainActor.assumeIsolated { keyboard.received(bytes) }
        }, context)
    }

    deinit {
        inputBuffer.deallocate()
    }

    private func received(_ bytes: [UInt8]) {
        guard let waiting, bytes.count >= 8, bytes[0] == EVision.reportID, bytes[3] == waiting.command else { return }
        self.waiting = nil
        waiting.continuation.resume(returning: bytes)
    }

    /// Sends one packet and returns the keyboard's answer, or nil on timeout.
    /// Packets go one at a time.
    @discardableResult
    func query(_ command: UInt8, offset: Int = 0, size: Int = 0, payload: [UInt8] = [], log: Bool = false) async -> [UInt8]? {
        while busy {
            await withCheckedContinuation { queue.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !queue.isEmpty { queue.removeFirst().resume() }
        }

        var packet = EVision.packet(command, offset: offset, size: size, payload: payload)
        let result = packet.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(EVision.reportID), buffer.baseAddress!, buffer.count)
        }
        if result != kIOReturnSuccess {
            Log.write("write cmd \(String(format: "%02x", command)) failed: \(String(format: "0x%08x", result))")
            return nil
        }
        if log { Log.write("sent  \(Log.hex(packet))") }

        let answer: [UInt8]? = await withCheckedContinuation { continuation in
            waiting = (command, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let waiting = self.waiting, waiting.command == command else { return }
                self.waiting = nil
                waiting.continuation.resume(returning: nil)
            }
        }
        if log { Log.write("reply \(answer.map { Log.hex($0) } ?? "none (timeout)")") }
        return answer
    }

    /// The payload of an answer, if the keyboard reported no error.
    private static func payload(_ answer: [UInt8]?) -> [UInt8]? {
        guard let answer, answer.count >= 8, answer[7] == 0 else { return nil }
        let size = Int(answer[4])
        guard size <= EVision.maxPayload, answer.count >= 8 + size else { return nil }
        return Array(answer[8..<(8 + size)])
    }

    // MARK: Detection (read-only)

    /// Asks for the capability block that only v2 firmware has. Reads
    /// nothing back into the keyboard and writes no settings.
    func detect() async {
        let answer = await query(EVision.Command.readCapabilities.rawValue, size: 7, log: true)
        if let data = Self.payload(answer), data.count >= 7, data[0] == 0xAA, data[1] == 0x55 {
            version = .v2
            mapSize = Int(data[5])
            Log.write("detected \(version.rawValue), map size \(mapSize), capabilities \(Log.hex(data))")
        } else {
            version = .v1
            Log.write("detected \(version.rawValue) (no v2 capability block)")
        }
    }

    // MARK: Reading the current settings (v2)

    private func currentProfileBase() async -> Int? {
        guard let data = Self.payload(await query(EVision.Command.readConfig.rawValue, offset: 0, size: 1)),
              let profile = data.first else { return nil }
        return Int(profile > 2 ? 0 : profile) * 0x40 + 1
    }

    /// v2 only: the 18 bytes of the active profile's lighting settings.
    private func readProfile(base: Int) async -> [UInt8]? {
        guard let data = Self.payload(await query(EVision.Command.readConfig.rawValue, offset: base, size: 18)),
              data.count == 18 else { return nil }
        return data
    }

    func readLighting() async -> EVision.Lighting? {
        guard version == .v2, let base = await currentProfileBase(), let data = await readProfile(base: base) else { return nil }
        Log.write("profile at 0x\(String(base, radix: 16)): \(Log.hex(data))")
        return EVision.Lighting(mode: data[0], brightness: min(data[1], 4), speed: min(data[2], 5),
                                direction: data[3], random: data[4] != 0,
                                red: data[5], green: data[6], blue: data[7])
    }

    // MARK: Writing settings

    func apply(_ lighting: EVision.Lighting) async {
        switch version {
        case .v2:
            await query(EVision.Command.begin.rawValue)
            guard let base = await currentProfileBase() else {
                Log.write("apply: could not read the active profile")
                await query(EVision.Command.end.rawValue)
                return
            }
            // Start from what is there, so settings this app does not know
            // (the custom-mode colour set, logo and edge) stay as they are.
            var data = await readProfile(base: base) ?? [UInt8](repeating: 0, count: 18)
            data[0] = lighting.mode
            data[1] = lighting.brightness
            data[2] = lighting.speed
            data[3] = lighting.direction
            data[4] = lighting.random ? 0xFF : 0
            data[5] = lighting.red
            data[6] = lighting.green
            data[7] = lighting.blue
            data[8] = 0
            await query(EVision.Command.writeConfig.rawValue, offset: base, size: data.count, payload: data)
            await query(EVision.Command.end.rawValue)
        case .v1:
            let data: [UInt8] = [lighting.mode, lighting.brightness, lighting.speed, lighting.direction,
                                 lighting.random ? 1 : 0, lighting.red, lighting.green, lighting.blue]
            await query(EVision.Command.writeConfig.rawValue, offset: 0, size: data.count, payload: data)
        }
        Log.write("applied mode \(String(format: "%02x", lighting.mode)) brightness \(lighting.brightness) speed \(lighting.speed) colour \(lighting.red),\(lighting.green),\(lighting.blue)")
    }

    // MARK: Live colour (v2)

    /// Sets every key to one colour without saving anything to the
    /// keyboard. The keyboard returns to its saved effect when updates stop.
    func showLive(red: UInt8, green: UInt8, blue: UInt8) async {
        guard version == .v2, mapSize > 0 else { return }
        var colours = [UInt8]()
        colours.reserveCapacity(mapSize * 3)
        for _ in 0..<mapSize { colours += [red, green, blue] }
        var offset = 0
        while offset < colours.count {
            let chunk = Array(colours[offset..<min(offset + EVision.maxPayload, colours.count)])
            await query(EVision.Command.dynamicColors.rawValue, offset: offset, size: chunk.count, payload: chunk)
            offset += chunk.count
        }
    }
}
