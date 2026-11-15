import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// The colour on the monitor, for lighting that follows the screen.
///
/// ScreenCaptureKit hands over a tiny (48×27) copy of the display about 20
/// times a second; each frame is boiled down to one colour. The external
/// monitor is used when one is connected, otherwise the main display.
/// macOS asks for Screen Recording permission the first time.
final class ScreenColor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Main thread: the colour of the latest frame.
    @MainActor var onColor: ((Double, Double, Double) -> Void)?
    /// Main thread: capture could not start or stopped by itself.
    @MainActor var onError: ((String) -> Void)?

    @MainActor private var stream: SCStream?
    @MainActor private var wanted = false
    private let queue = DispatchQueue(label: "com.parobita.parvus.screen", qos: .userInteractive)

    @MainActor func start() {
        guard !wanted else { return }
        wanted = true
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.wanted, self.stream == nil else { return }
                guard let display = Self.pick(content.displays) else {
                    self.fail("Ekran bulunamadı.")
                    return
                }
                let config = SCStreamConfiguration()
                config.width = 48
                config.height = 27
                config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.queueDepth = 3
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard self.wanted else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                Log.write("screen sync started on display \(display.displayID) (\(display.width)×\(display.height))")
            } catch {
                Log.write("screen sync could not start: \(error.localizedDescription)")
                self.fail("Ekran kaydı izni gerekli: Sistem Ayarları > Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı'nda Parvus'u aç.")
            }
        }
    }

    @MainActor func stop() {
        wanted = false
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
        Log.write("screen sync stopped")
    }

    @MainActor private func fail(_ message: String) {
        wanted = false
        stream = nil
        onError?(message)
    }

    /// The external monitor if there is one, otherwise the main display.
    private static func pick(_ displays: [SCDisplay]) -> SCDisplay? {
        displays.first { CGDisplayIsBuiltin($0.displayID) == 0 }
            ?? displays.first { $0.displayID == CGMainDisplayID() }
            ?? displays.first
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("screen sync stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.stream === stream else { return }
                self.fail("Ekran yakalama durdu. Senkronu kapatıp yeniden aç.")
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Frames that only repeat an unchanged screen carry no image.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete { return }
        guard let pixels = sampleBuffer.imageBuffer, let colour = Self.colour(of: pixels) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onColor?(colour.0, colour.1, colour.2) }
        }
    }

    /// One colour for the frame, 0...1 per channel. Colourful pixels count
    /// far more than grey ones, so a small bright element on a dark scene
    /// still sets the hue; the overall brightness of the screen sets how
    /// bright the result is.
    private static func colour(of buffer: CVPixelBuffer) -> (Double, Double, Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var red = 0.0, green = 0.0, blue = 0.0, weights = 0.0, light = 0.0
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                let b = Double(row[x * 4]) / 255
                let g = Double(row[x * 4 + 1]) / 255
                let r = Double(row[x * 4 + 2]) / 255
                let high = max(r, g, b), low = min(r, g, b)
                let saturation = high > 0 ? (high - low) / high : 0
                let weight = 0.03 + saturation * saturation * high
                red += r * weight
                green += g * weight
                blue += b * weight
                weights += weight
                light += high
            }
        }
        let count = Double(width * height)
        guard count > 0, weights > 0 else { return nil }
        var r = red / weights, g = green / weights, b = blue / weights

        // Full-strength hue, then a little more saturation: LEDs wash out.
        let high = max(r, g, b)
        guard high > 0.001 else { return (0, 0, 0) }
        r /= high; g /= high; b /= high
        let grey = (r + g + b) / 3
        r = grey + (r - grey) * 1.35
        g = grey + (g - grey) * 1.35
        b = grey + (b - grey) * 1.35

        // A dark screen dims the keys, but never to fully off.
        let level = min(max(pow(light / count, 0.7), 0.12), 1)
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) * level }
        return (clamp(r), clamp(g), clamp(b))
    }
}
