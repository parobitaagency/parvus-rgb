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
        }
    }
    /// Lights off between `nightStart` and `nightEnd` (minutes after midnight).
    @Published var nightMode: Bool { didSet { UserDefaults.standard.set(nightMode, forKey: "nightMode"); checkNight() } }
    @Published var nightStart: Int { didSet { UserDefaults.standard.set(nightStart, forKey: "nightStart"); checkNight() } }
    @Published var nightEnd: Int { didSet { UserDefaults.standard.set(nightEnd, forKey: "nightEnd"); checkNight() } }
    @Published private(set) var isNight = false
    @Published var presets: [Preset] = [] {
        didSet { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "presets") } }
    }

    private let music = MusicColor()
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
        defaults.register(defaults: ["offWhileAsleep": true, "followsMusic": false, "nightMode": false,
                                     "nightStart": 23 * 60, "nightEnd": 7 * 60])
        offWhileAsleep = defaults.bool(forKey: "offWhileAsleep")
        followsMusic = defaults.bool(forKey: "followsMusic")
        nightMode = defaults.bool(forKey: "nightMode")
        nightStart = defaults.integer(forKey: "nightStart")
        nightEnd = defaults.integer(forKey: "nightEnd")
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
        music.onColor = { [weak self] red, green, blue in
            guard let self, self.followsMusic else { return }
            self.lighting.random = false
            self.lighting.red = red
            self.lighting.green = green
            self.lighting.blue = blue
        }
        if followsMusic { music.start() }
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
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        presets.append(Preset(name: trimmed.isEmpty ? "Ayar \(presets.count + 1)" : trimmed, lighting: lighting))
    }

    func load(_ preset: Preset) { lighting = preset.lighting }

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
            connected = true
            versionName = keyboard.version.rawValue
            status = "Rampage Parvus bağlı"
            if let current = await keyboard.readLighting() {
                loading = true
                lighting = current
                loading = false
                save()
            }
        }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let keyboard, keyboard.device == device else { return }
        Log.write("keyboard removed")
        self.keyboard = nil
        connected = false
        versionName = ""
        status = "Klavye takılı değil"
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
        pushEffective()
    }

    private func wake() {
        guard asleep else { return }
        asleep = false
        checkNight()
        pushEffective()
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
