import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardModel.shared.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Parvus")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = KeyboardModel.shared
        let header = NSMenuItem(title: model.connected ? "Rampage Parvus bağlı" : model.status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item(model.lighting.brightness == 0 ? "Işıkları Aç" : "Işıkları Kapat") {
            model.lighting.brightness == 0 ? model.turnOn() : model.turnOff()
        })
        menu.addItem(item("Parvus'u Göster", key: ",") { [weak self] in self?.showWindow() })
        menu.addItem(.separator())
        menu.addItem(item("Çık", key: "q") { NSApp.terminate(nil) })
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Parvus RGB"
            window.contentViewController = NSHostingController(rootView: ContentView())
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func item(_ title: String, key: String = "", _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        ActionItem(title: title, key: key, action: action)
    }
}

final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, key: String = "", action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
