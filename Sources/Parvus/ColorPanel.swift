import AppKit
import SwiftUI

/// Every colour at once: hue left to right, saturation top to bottom, plus
/// exact R, G, B and hex entry. The keyboard's own brightness is set
/// separately, so the panel stays at full value.
struct ColorPanel: View {
    @Binding var red: UInt8
    @Binding var green: UInt8
    @Binding var blue: UInt8

    @State private var hexText = ""

    private var hsv: (h: Double, s: Double) {
        let colour = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        return (Double(colour.hueComponent), Double(colour.saturationComponent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            spectrum
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255))
                    .frame(width: 44, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                channel("R", value: $red, tint: .red)
                channel("G", value: $green, tint: .green)
                channel("B", value: $blue, tint: .blue)
                HStack(spacing: 4) {
                    Text("#").foregroundStyle(.secondary)
                    TextField("FFFFFF", text: $hexText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .font(.body.monospaced())
                        .onSubmit(applyHex)
                }
            }
        }
        .onAppear(perform: syncHex)
        .onChange(of: [red, green, blue]) { _, _ in syncHex() }
    }

    private var spectrum: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(.white, lineWidth: 2.5)
                    .background(Circle().fill(Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)))
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .position(x: hsv.h * size.width, y: (1 - hsv.s) * size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let hue = min(max(value.location.x / max(size.width, 1), 0), 0.9999)
                let saturation = 1 - min(max(value.location.y / max(size.height, 1), 0), 1)
                set(NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1))
            })
        }
        .frame(height: 150)
    }

    private func channel(_ label: String, value: Binding<UInt8>, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.callout.weight(.semibold)).foregroundStyle(tint)
            TextField(label, value: Binding(get: { Int(value.wrappedValue) },
                                            set: { value.wrappedValue = UInt8(min(max($0, 0), 255)) }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .multilineTextAlignment(.trailing)
        }
    }

    private func set(_ colour: NSColor) {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return }
        red = UInt8((Double(rgb.redComponent) * 255).rounded())
        green = UInt8((Double(rgb.greenComponent) * 255).rounded())
        blue = UInt8((Double(rgb.blueComponent) * 255).rounded())
    }

    private func syncHex() {
        hexText = String(format: "%02X%02X%02X", red, green, blue)
    }

    private func applyHex() {
        let digits = hexText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = Int(digits, radix: 16) else { syncHex(); return }
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
    }
}
