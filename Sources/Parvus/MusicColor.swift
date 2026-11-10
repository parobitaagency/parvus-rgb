import AppKit

/// The colour of the album artwork playing in Music or Spotify.
///
/// Both apps post a distributed notification when the track changes; the
/// artwork is then read once with AppleScript. Nothing polls, and no app is
/// ever launched by it: each script runs only while its app is running.
@MainActor
final class MusicColor: NSObject {
    var onColor: ((UInt8, UInt8, UInt8) -> Void)?
    private var lastTrack = ""
    private var observing = false
    private let queue = DispatchQueue(label: "com.parobita.parvus.music", qos: .utility)

    func start() {
        guard !observing else { return }
        observing = true
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            center.addObserver(self, selector: #selector(changed(_:)), name: .init(name), object: nil)
        }
        refresh()
    }

    func stop() {
        guard observing else { return }
        observing = false
        DistributedNotificationCenter.default().removeObserver(self)
        lastTrack = ""
    }

    @objc private func changed(_ note: Notification) {
        MainActor.assumeIsolated { refresh() }
    }

    private func refresh() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let music = running.contains("com.apple.Music")
        let spotify = running.contains("com.spotify.client")
        queue.async { [weak self] in
            var result: (id: String, image: NSImage?)?
            if music, let id = Self.run("tell application \"Music\" to if player state is playing then return persistent ID of current track")?.stringValue {
                result = (id, Self.run("tell application \"Music\" to get raw data of artwork 1 of current track").flatMap { NSImage(data: $0.data) })
            } else if spotify, let id = Self.run("tell application \"Spotify\" to if player state is playing then return id of current track")?.stringValue,
                      let urlText = Self.run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
                      let url = URL(string: urlText), let data = try? Data(contentsOf: url) {
                result = (id, NSImage(data: data))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let result, result.id != self.lastTrack, let image = result.image,
                          let colour = image.vividColor else { return }
                    self.lastTrack = result.id
                    Log.write("music colour for track \(result.id): \(colour.0),\(colour.1),\(colour.2)")
                    self.onColor?(colour.0, colour.1, colour.2)
                }
            }
        }
    }

    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                Log.write("Automation permission missing for music colour")
            }
            return nil
        }
        return result
    }
}

extension NSImage {
    /// The artwork's most colourful tone, pushed to full saturation and
    /// brightness so it reads on LEDs (which cannot show dark or grey).
    var vividColor: (UInt8, UInt8, UInt8)? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Weight hues by how colourful each pixel is; grey and black count little.
        var buckets = [Double](repeating: 0, count: 36)
        var hueSums = [Double](repeating: 0, count: 36)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let colour = NSColor(srgbRed: CGFloat(pixels[index]) / 255, green: CGFloat(pixels[index + 1]) / 255,
                                 blue: CGFloat(pixels[index + 2]) / 255, alpha: 1)
            let s = Double(colour.saturationComponent), v = Double(colour.brightnessComponent)
            let weight = s * s * v
            let hue = Double(colour.hueComponent)
            let bucket = min(Int(hue * 36), 35)
            buckets[bucket] += weight
            hueSums[bucket] += hue * weight
        }
        guard let best = buckets.indices.max(by: { buckets[$0] < buckets[$1] }) else { return nil }
        // A grey or black-and-white cover: white light.
        guard buckets[best] > 0.5 else { return (255, 255, 255) }
        let hue = hueSums[best] / buckets[best]
        let vivid = NSColor(hue: CGFloat(hue), saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB)!
        return (UInt8((Double(vivid.redComponent) * 255).rounded()),
                UInt8((Double(vivid.greenComponent) * 255).rounded()),
                UInt8((Double(vivid.blueComponent) * 255).rounded()))
    }
}
