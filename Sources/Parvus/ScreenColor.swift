import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// The colour on the monitor, for lighting that follows the screen.
///
/// ScreenCaptureKit hands over a tiny (60×20) copy of the display about 20
/// times a second; each frame is boiled down to a grid of `columns` × `rows`
/// colours, one per keyboard area. The external
/// monitor is used when one is connected, otherwise the main display.
/// macOS asks for Screen Recording permission the first time.
final class ScreenColor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let columns = 15
    static let rows = 5
    /// Main thread: the latest frame as `columns × rows` cells, row by row
    /// from the top, three values (0...1) per cell.
    @MainActor var onColors: (([Double]) -> Void)?
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
                config.width = Self.columns * 4
                config.height = Self.rows * 4
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
        guard let pixels = sampleBuffer.imageBuffer, let grid = Self.grid(of: pixels) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onColors?(grid) }
        }
    }

    /// One colour per cell. Within a cell, colourful pixels count far more
    /// than grey ones, so a pink element on a dark background still reads as
    /// pink. Every colour is pushed to full strength (LEDs look dim and
    /// washed out otherwise); only nearly black areas are dimmed, and never
    /// below half.
    private static func grid(of buffer: CVPixelBuffer) -> [Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        guard width > 0, height > 0 else { return nil }

        var sums = [Double](repeating: 0, count: columns * rows * 5)   // r, g, b, weight, light
        for y in 0..<height {
            let row = bytes + y * rowBytes
            let cellY = min(y * rows / height, rows - 1)
            for x in 0..<width {
                let b = Double(row[x * 4]) / 255
                let g = Double(row[x * 4 + 1]) / 255
                let r = Double(row[x * 4 + 2]) / 255
                let high = max(r, g, b), low = min(r, g, b)
                let saturation = high > 0 ? (high - low) / high : 0
                let weight = 0.03 + saturation * saturation * high
                let cell = (cellY * columns + min(x * columns / width, columns - 1)) * 5
                sums[cell] += r * weight
                sums[cell + 1] += g * weight
                sums[cell + 2] += b * weight
                sums[cell + 3] += weight
                sums[cell + 4] = max(sums[cell + 4], high)
            }
        }

        var result = [Double](repeating: 0, count: columns * rows * 3)
        for cell in 0..<(columns * rows) {
            let weight = sums[cell * 5 + 3]
            guard weight > 0 else { continue }
            var r = sums[cell * 5] / weight, g = sums[cell * 5 + 1] / weight, b = sums[cell * 5 + 2] / weight
            let high = max(r, g, b)
            guard high > 0.001 else { continue }
            r /= high; g /= high; b /= high
            let grey = (r + g + b) / 3
            r = grey + (r - grey) * 1.35
            g = grey + (g - grey) * 1.35
            b = grey + (b - grey) * 1.35
            // Brightest pixel of the cell: a cell that is all black dims to half.
            let level = 0.5 + 0.5 * min(sums[cell * 5 + 4] / 0.25, 1)
            result[cell * 3] = min(max(r, 0), 1) * level
            result[cell * 3 + 1] = min(max(g, 0), 1) * level
            result[cell * 3 + 2] = min(max(b, 0), 1) * level
        }
        return result
    }
}
