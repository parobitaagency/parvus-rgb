import AppKit
import IOKit.hid
import SwiftUI

/// The lighting effects built into the keyboard.
struct Effect: Identifiable, Hashable {
    let id: UInt8
    let name: String
    let symbol: String
    var usesColour = true
    var usesSpeed = true
    var usesDirection = false

    static let all: [Effect] = [
        Effect(id: 0x06, name: "Sabit renk", symbol: "circle.fill", usesSpeed: false),
        Effect(id: 0x05, name: "Nefes", symbol: "wind"),
        Effect(id: 0x04, name: "Renk döngüsü", symbol: "arrow.triangle.2.circlepath", usesColour: false),
        Effect(id: 0x01, name: "Kısa dalga", symbol: "water.waves", usesDirection: true),
        Effect(id: 0x02, name: "Uzun dalga", symbol: "wave.3.right", usesDirection: true),
        Effect(id: 0x03, name: "Renk çarkı", symbol: "circle.hexagongrid", usesDirection: true),
        Effect(id: 0x0C, name: "Dikey gökkuşağı", symbol: "rainbow", usesColour: false, usesDirection: true),
        Effect(id: 0x12, name: "Dairesel gökkuşağı", symbol: "circle.dashed", usesColour: false, usesDirection: true),
        Effect(id: 0x07, name: "Bastığın tuş", symbol: "hand.tap"),
        Effect(id: 0x08, name: "Dalgalanma", symbol: "dot.radiowaves.left.and.right"),
        Effect(id: 0x09, name: "Tuştan çizgi", symbol: "line.diagonal.arrow"),
        Effect(id: 0x0A, name: "Hızlı yıldızlar", symbol: "sparkles"),
        Effect(id: 0x0F, name: "Yavaş yıldızlar", symbol: "star"),
        Effect(id: 0x0B, name: "Çiçek", symbol: "camera.macro"),
        Effect(id: 0x0D, name: "Kasırga", symbol: "tornado"),
        Effect(id: 0x0E, name: "Birikme", symbol: "square.stack.3d.up"),
        Effect(id: 0x10, name: "İki yön", symbol: "arrow.left.and.right"),
        Effect(id: 0x11, name: "Aşma", symbol: "arrow.up.right"),
        Effect(id: 0x14, name: "Özel (kayıtlı)", symbol: "keyboard", usesColour: false, usesSpeed: false),
    ]
}

/// A saved combination of effect, colour, brightness and speed.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lighting: EVision.Lighting
}

@MainActor
final class KeyboardModel: ObservableObject {
    static let shared = KeyboardModel()

    @Published private(set) var status = "Klavye aranıyor…"
    @Published private(set) var connected = false
    @Published private(set) var versionName = ""
    @Published private(set) var needsPermission = false
    @Published var lighting = EVision.Lighting() { didSet { if lighting != oldValue { scheduleApply() } } }
    @Published var offWhileAsleep: Bool { didSet { UserDefaults.standard.set(offWhileAsleep, forKey: "offWhileAsleep") } }
    /// The keyboard takes the colour of the album playing in Music or Spotify.
    @Published var followsMusic: Bool {
        didSet {
            UserDefaults.standard.set(followsMusic, forKey: "followsMusic")
            followsMusic ? music.start() : music.stop()
            if followsMusic { followsScreen = false }
        }
    }
    /// The keyboard follows the colours on the monitor, live (v2 firmware).
    @Published var followsScreen: Bool {
        didSet {
            guard followsScreen != oldValue else { return }
            UserDefaults.standard.set(followsScreen, forKey: "followsScreen")
            if followsScreen {
                followsMusic = false
                screenError = nil
            }
            updateScreenSync()
        }
    }
    @Published private(set) var screenError: String?
    /// Live colours need EVision v2; v1 keyboards would have to save every frame.
    var supportsLive: Bool { keyboard?.supportsLive ?? false }
    /// Lights off between `nightStart` and `nightEnd` (minutes after midnight).
    @Published var nightMode: Bool { didSet { UserDefaults.standard.set(nightMode, forKey: "nightMode"); checkNight() } }
    @Published var nightStart: Int { didSet { UserDefaults.standard.set(nightStart, forKey: "nightStart"); checkNight() } }
    @Published var nightEnd: Int { didSet { UserDefaults.standard.set(nightEnd, forKey: "nightEnd"); checkNight() } }
    @Published private(set) var isNight = false
    @Published var presets: [Preset] = [] {
        didSet { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "presets") } }
    }

    /// The user's own saved colours (0xRRGGBB), shown next to the built-in swatches.
    @Published var customColours: [Int] = [] {
        didSet { UserDefaults.standard.set(customColours, forKey: "customColours") }
    }

    private let music = MusicColor()
    private let screen = ScreenColor()
    private var screenTarget: [Double]?
    private var screenShown: [Double]?
    private var screenSent: [UInt8]?
    private var screenSentAt = Date.distantPast
    private var screenFailures = 0
    /// Last time a key was pressed on the Parvus; live colours pause while typing.
    private var lastKeyPress = Date.distantPast
    private var keyManager: IOHIDManager?
    /// Until this time the keys show the zone test pattern.
    private var testUntil: Date?
    private var testTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var hotkey: Hotkey?
    private var nightTimer: Timer?

    private var manager: IOHIDManager?
    private var keyboard: EVisionKeyboard?
    private var applyTask: Task<Void, Never>?
    /// Set while the app itself changes `lighting` (reading the keyboard),
    /// so it is not written straight back.
    private var loading = false
    private var asleep = false

    var effect: Effect { Effect.all.first { $0.id == lighting.mode } ?? Effect.all[0] }

    var colour: Color {
        get { Color(red: Double(lighting.red) / 255, green: Double(lighting.green) / 255, blue: Double(lighting.blue) / 255) }
        set {
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            lighting.red = UInt8(Double(rgb.redComponent * 255).rounded().clamped(0, 255))
            lighting.green = UInt8(Double(rgb.greenComponent * 255).rounded().clamped(0, 255))
            lighting.blue = UInt8(Double(rgb.blueComponent * 255).rounded().clamped(0, 255))
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["offWhileAsleep": true, "followsMusic": false, "followsScreen": false, "nightMode": false,
                                     "nightStart": 23 * 60, "nightEnd": 7 * 60])
        offWhileAsleep = defaults.bool(forKey: "offWhileAsleep")
        followsMusic = defaults.bool(forKey: "followsMusic")
        // Experimental: never starts by itself at launch.
        followsScreen = false
        nightMode = defaults.bool(forKey: "nightMode")
        nightStart = defaults.integer(forKey: "nightStart")
        nightEnd = defaults.integer(forKey: "nightEnd")
        customColours = defaults.array(forKey: "customColours") as? [Int] ?? []
        if let data = defaults.data(forKey: "presets"), let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        }
        if let data = UserDefaults.standard.data(forKey: "lighting"),
           let saved = try? JSONDecoder().decode(EVision.Lighting.self, from: data) {
            loading = true
            lighting = saved
            loading = false
        }
    }

    // MARK: Connection

    func start() {
        Log.write("Parvus started")
        // The lighting interface sits on the same USB interface as the keys,
        // so macOS asks for Input Monitoring before it can be opened.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            needsPermission = !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: EVision.vendorID,
            kIOHIDProductIDKey: EVision.productID,
            kIOHIDDeviceUsagePageKey: EVision.usagePage,
            kIOHIDDeviceUsageKey: EVision.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let model = Unmanaged<KeyboardModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let model = Unmanaged<KeyboardModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.detach(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.write("HID manager open: \(String(format: "0x%08x", result))")
        self.manager = manager
        observeSleep()
        watchKeys()
        music.onColor = { [weak self] red, green, blue in
            guard let self, self.followsMusic else { return }
            self.lighting.random = false
            self.lighting.red = red
            self.lighting.green = green
            self.lighting.blue = blue
        }
        if followsMusic { music.start() }
        screen.onColors = { [weak self] grid in self?.screenTarget = grid }
        screen.onError = { [weak self] message in
            guard let self else { return }
            self.screenError = message
            self.followsScreen = false
        }
        hotkey = Hotkey { [weak self] in self?.toggle() }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNight() }
        }
        RunLoop.main.add(timer, forMode: .common)
        nightTimer = timer
        checkNight()
    }

    // MARK: Night mode

    private func checkNight() {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minute = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let night: Bool
        if !nightMode || nightStart == nightEnd {
            night = false
        } else if nightStart < nightEnd {
            night = minute >= nightStart && minute < nightEnd
        } else {
            night = minute >= nightStart || minute < nightEnd
        }
        guard night != isNight else { return }
        isNight = night
        Log.write(night ? "night mode: lights off" : "night mode: lights back")
        pushEffective()
        updateScreenSync()
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        presets.append(Preset(name: trimmed.isEmpty ? "Ayar \(presets.count + 1)" : trimmed, lighting: lighting))
    }

    func load(_ preset: Preset) { lighting = preset.lighting }

    // MARK: Custom colours

    var currentHex: Int { Int(lighting.red) << 16 | Int(lighting.green) << 8 | Int(lighting.blue) }

    /// Saves the colour now on the keyboard; an existing one moves to the end.
    func saveCurrentColour() {
        let hex = currentHex
        customColours.removeAll { $0 == hex }
        customColours.append(hex)
        if customColours.count > 12 { customColours.removeFirst(customColours.count - 12) }
    }

    func deleteColour(_ hex: Int) { customColours.removeAll { $0 == hex } }

    func useColour(_ hex: Int) {
        lighting.random = false
        lighting.red = UInt8((hex >> 16) & 0xFF)
        lighting.green = UInt8((hex >> 8) & 0xFF)
        lighting.blue = UInt8(hex & 0xFF)
    }

    func delete(_ preset: Preset) { presets.removeAll { $0.id == preset.id } }

    func toggle() {
        lighting.brightness == 0 ? turnOn() : turnOff()
    }

    func retryPermission() {
        needsPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func attach(_ device: IOHIDDevice) {
        guard keyboard == nil else { return }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.write("keyboard found, open: \(String(format: "0x%08x", opened))")
        guard opened == kIOReturnSuccess else {
            status = "Klavye bulundu ama açılamadı. Giriş İzleme iznini kontrol et."
            needsPermission = true
            return
        }
        needsPermission = false
        let keyboard = EVisionKeyboard(device: device)
        self.keyboard = keyboard
        status = "Bağlanıyor…"
        Task {
            await keyboard.detect()
            if keyboard.permissionDenied {
                status = "İzin gerekli: Giriş İzleme'de Parvus'u silip yeniden ekle."
                needsPermission = true
                return
            }
            connected = true
            versionName = keyboard.version.rawValue
            status = "Rampage Parvus bağlı"
            if let current = await keyboard.readLighting() {
                loading = true
                lighting = current
                loading = false
                save()
            }
            objectWillChange.send()
            updateScreenSync()
        }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let keyboard, keyboard.device == device else { return }
        Log.write("keyboard removed")
        self.keyboard = nil
        connected = false
        versionName = ""
        status = "Klavye takılı değil"
        updateScreenSync()
    }

    // MARK: Applying

    private func scheduleApply() {
        save()
        guard !loading else { return }
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            // Wait for a pause, so dragging across the colours writes once.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, let keyboard = self.keyboard else { return }
            await keyboard.apply(self.effective)
        }
    }

    /// What the keyboard should show now: dark while the Mac sleeps or at night.
    private var effective: EVision.Lighting {
        var shown = lighting
        if asleep || isNight { shown.brightness = 0 }
        return shown
    }

    private func pushEffective() {
        guard let keyboard else { return }
        let shown = effective
        Task { await keyboard.apply(shown) }
    }

    // MARK: Screen sync

    /// Runs the capture and the send loop only while they can do something:
    /// sync on, a v2 keyboard attached, the Mac awake and not night.
    private func updateScreenSync() {
        let active = followsScreen && supportsLive && !asleep && !isNight
        if active {
            screen.start()
            guard screenTask == nil else { return }
            screenShown = nil
            screenSent = nil
            screenFailures = 0
            screenTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sendScreenFrame()
                    // 10 updates a second at most: faster floods the keyboard,
                    // which then misreads keys.
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            screen.stop()
            guard let task = screenTask else { return }
            task.cancel()
            screenTask = nil
            screenTarget = nil
            screenShown = nil
            screenSent = nil
            // Leave live mode properly, then back to the saved effect.
            if let keyboard {
                let shown = effective
                Task {
                    await keyboard.endLive()
                    await keyboard.apply(shown)
                }
            }
        }
    }

    /// Eases the keys toward the latest screen colours, so cuts in a video
    /// do not flicker, and sends only when something visibly changed.
    private func sendScreenFrame() async {
        guard let keyboard, let target = screenTarget else { return }
        if let testUntil, testUntil > Date() { return }
        // Lights switched off (button or ⌃⌥⌘L): leave them off.
        guard lighting.brightness > 0 else {
            screenShown = nil
            screenSent = nil
            return
        }
        var shown = screenShown ?? target
        if shown.count != target.count { shown = target }
        for index in shown.indices { shown[index] += (target[index] - shown[index]) * 0.35 }
        screenShown = shown
        let slots = Self.slots(keyboard.mapSize) { column, row in
            let cell = (row * ScreenColor.columns + column) * 3
            return (shown[cell], shown[cell + 1], shown[cell + 2])
        }
        // Hold off while typing, so colour packets never cross key presses.
        guard Date().timeIntervalSince(lastKeyPress) > 0.6 else { return }
        let ok: Bool
        if slots == screenSent {
            // Unchanged: keep the live colours up the way OpenRGB does, with
            // one zero byte in the blank slot every 200 ms.
            guard Date().timeIntervalSince(screenSentAt) > 0.2 else { return }
            ok = await keyboard.keepLiveAlive()
        } else {
            ok = await keyboard.sendLive(slots, changedSince: screenSent)
        }
        if ok {
            screenSent = slots
            screenSentAt = Date()
            screenFailures = 0
        } else {
            screenSent = nil
            screenFailures += 1
            Log.write("screen sync: keyboard did not answer (\(screenFailures))")
            if screenFailures >= 3 {
                screenError = "Klavye yanıt vermedi, senkron durduruldu. Klavyeyi çıkarıp tak."
                followsScreen = false
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Watches the Parvus's own key, system and consumer reports (Input
    /// Monitoring is already granted for the lighting interface): key
    /// presses pause the live colours, and a power or sleep signal while
    /// they run stops screen sync on the spot.
    private func watchKeys() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let usages: [(Int, Int)] = [
            (kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard),
            (kHIDPage_GenericDesktop, kHIDUsage_GD_SystemControl),
            (kHIDPage_Consumer, kHIDUsage_Csmr_ConsumerControl),
        ]
        let matching: [[String: Any]] = usages.map { page, usage in
            [kIOHIDVendorIDKey: EVision.vendorID, kIOHIDProductIDKey: EVision.productID,
             kIOHIDDeviceUsagePageKey: page, kIOHIDDeviceUsageKey: usage]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            let model = Unmanaged<KeyboardModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.keyEvent(page: page, usage: usage, pressed: pressed) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        keyManager = manager
    }

    private func keyEvent(page: Int, usage: Int, pressed: Bool) {
        if page == kHIDPage_KeyboardOrKeypad { lastKeyPress = Date() }
        let power = (page == kHIDPage_GenericDesktop && [kHIDUsage_GD_SystemPowerDown, kHIDUsage_GD_SystemSleep].contains(usage))
            || (page == kHIDPage_Consumer && [kHIDUsage_Csmr_Power, kHIDUsage_Csmr_Sleep, kHIDUsage_Csmr_SleepMode].contains(usage))
            || (page == kHIDPage_KeyboardOrKeypad && usage == kHIDUsage_KeyboardPower)
        guard power, pressed, screenTask != nil || testUntil != nil else { return }
        Log.write("power signal from the keyboard (page \(page), usage \(usage)) while live colours ran: screen sync stopped")
        testTask?.cancel()
        testUntil = nil
        screenError = "Klavye güç sinyali gönderdi, senkron güvenlik için durduruldu. Klavyeyi çıkarıp tak."
        followsScreen = false
        if let keyboard { Task { await keyboard.endLive() } }
    }

    /// The slots of the dynamic map that belong to a key (OpenRGB's EVision v2
    /// map). Every other slot stays 0, as OpenRGB leaves it; slot 6 is the
    /// blank one the keyboard is kept alive through. Earlier versions
    /// coloured every slot, and the Parvus then sent System Power.
    private static let keySlots: Set<Int> = [
        0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 24, 25, 26, 27, 28,
        30, 31, 32, 33, 34, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 54, 55, 56, 57, 58,
        60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86,
        89, 90, 91, 92, 94, 95, 96, 97, 98, 101, 103, 104, 105, 106, 109, 110, 111, 112, 113, 115, 116, 117,
        118, 119, 121, 122, 124,
    ]

    /// Builds the dynamic map: for every slot, the colour of the screen area
    /// above that key. Slot / 6 is the key column, slot % 6 its row; the
    /// Parvus is a 60% board, so its keys use the first 15 columns.
    private static func slots(_ mapSize: Int, colour: (Int, Int) -> (Double, Double, Double)) -> [UInt8] {
        func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        var bytes = [UInt8](repeating: 0, count: mapSize * 3)
        for slot in 0..<mapSize where keySlots.contains(slot) {
            let column = min(slot / 6, ScreenColor.columns - 1)
            // Six map rows onto the five screen rows.
            let row = min(Int((Double(slot % 6) * Double(ScreenColor.rows - 1) / 5).rounded()), ScreenColor.rows - 1)
            let (r, g, b) = colour(column, row)
            bytes[slot * 3] = byte(r)
            bytes[slot * 3 + 1] = byte(g)
            bytes[slot * 3 + 2] = byte(b)
        }
        return bytes
    }

    /// Five seconds of a fixed pattern to check the key map: left half red,
    /// right half blue, top row white.
    func runZoneTest() {
        guard let keyboard, keyboard.supportsLive else { return }
        testTask?.cancel()
        testUntil = Date().addingTimeInterval(5)
        screenSent = nil
        let slots = Self.slots(keyboard.mapSize) { column, row in
            if row == 0 { return (1, 1, 1) }
            return column < ScreenColor.columns / 2 ? (1, 0, 0) : (0, 0.3, 1)
        }
        Log.write("zone test: map size \(keyboard.mapSize)")
        testTask = Task { [weak self] in
            // The keyboard drops live colours when they stop coming, so repeat.
            for _ in 0..<25 {
                guard !Task.isCancelled else { return }
                await keyboard.showLive(slots)
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, !Task.isCancelled else { return }
            self.testUntil = nil
            if self.screenTask == nil {
                await keyboard.endLive()
                self.pushEffective()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lighting) {
            UserDefaults.standard.set(data, forKey: "lighting")
        }
    }

    func turnOff() { lighting.brightness = 0 }

    func turnOn() {
        if lighting.brightness == 0 { lighting.brightness = 4 }
    }

    // MARK: Sleep

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleep() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
        }
    }

    private func sleep() {
        guard offWhileAsleep, !asleep else { return }
        asleep = true
        updateScreenSync()
        pushEffective()
    }

    private func wake() {
        guard asleep else { return }
        asleep = false
        checkNight()
        pushEffective()
        updateScreenSync()
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
