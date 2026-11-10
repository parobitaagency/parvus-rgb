import SwiftUI

struct ContentView: View {
    @ObservedObject var model: KeyboardModel = .shared

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 10)]

    @State private var presetName = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.needsPermission { permissionBanner }
            Group {
                effects
                controls
                extras
            }
            .disabled(!model.connected)
            .opacity(model.connected ? 1 : 0.5)
            Spacer(minLength: 0)
        }
        .padding(22)
        }
        .frame(minWidth: 600, minHeight: 820)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.colour.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "keyboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Rampage Parvus").font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(model.connected ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.status).foregroundStyle(.secondary)
                    if !model.versionName.isEmpty {
                        Text("· \(model.versionName)").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
            Spacer()
            Button(model.lighting.brightness == 0 ? "Aç" : "Kapat") {
                model.lighting.brightness == 0 ? model.turnOn() : model.turnOff()
            }
            .controlSize(.large)
            .disabled(!model.connected)
        }
    }

    private var permissionBanner: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Klavyenin ışıklarına erişmek için Sistem Ayarları > Gizlilik ve Güvenlik > Giriş İzleme'de Parvus'u aç, sonra uygulamayı yeniden başlat.")
                .font(.callout)
            Spacer()
            Button("Ayarları Aç") { model.retryPermission() }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Efekt").font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Effect.all) { effect in
                    let selected = effect.id == model.lighting.mode
                    Button {
                        model.lighting.mode = effect.id
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: effect.symbol).font(.system(size: 18))
                            Text(effect.name).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var controls: some View {
        let effect = model.effect
        return Form {
            if effect.usesColour {
                Toggle("Rastgele renkler", isOn: $model.lighting.random)
                ColorPanel(red: $model.lighting.red, green: $model.lighting.green, blue: $model.lighting.blue)
                    .disabled(model.lighting.random)
                    .opacity(model.lighting.random ? 0.4 : 1)
                HStack {
                    ForEach(Self.swatches, id: \.self) { hex in
                        Button {
                            model.lighting.random = false
                            model.lighting.red = UInt8((hex >> 16) & 0xFF)
                            model.lighting.green = UInt8((hex >> 8) & 0xFF)
                            model.lighting.blue = UInt8(hex & 0xFF)
                        } label: {
                            Circle()
                                .fill(Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            LabeledContent("Parlaklık") {
                Slider(value: Binding(get: { Double(model.lighting.brightness) },
                                      set: { model.lighting.brightness = UInt8($0.rounded()) }),
                       in: 0...4, step: 1)
            }
            if effect.usesSpeed {
                LabeledContent("Hız") {
                    // The keyboard counts 0 as fastest; the slider goes slow → fast.
                    Slider(value: Binding(get: { Double(5 - Int(model.lighting.speed)) },
                                          set: { model.lighting.speed = UInt8(5 - Int($0.rounded())) }),
                           in: 0...5, step: 1)
                }
            }
            if effect.usesDirection {
                Picker("Yön", selection: $model.lighting.direction) {
                    Text("Bir yön").tag(UInt8(0))
                    Text("Ters yön").tag(UInt8(1))
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    private var extras: some View {
        Form {
            Section("Otomatik") {
                Toggle(isOn: $model.followsMusic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Müziğe göre renk")
                        Text("Apple Music ya da Spotify'da şarkı değişince klavye albüm kapağının rengini alır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Mac uyurken ışıkları kapat", isOn: $model.offWhileAsleep)
                Toggle(isOn: $model.nightMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gece modu")
                        Text(model.isNight ? "Şu an gece: ışıklar kapalı." : "Seçtiğin saatler arasında ışıklar kapanır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.nightMode {
                    DatePicker("Kapanış", selection: time($model.nightStart), displayedComponents: .hourAndMinute)
                    DatePicker("Açılış", selection: time($model.nightEnd), displayedComponents: .hourAndMinute)
                }
            }
            Section("Hazır ayarlar") {
                ForEach(model.presets) { preset in
                    HStack {
                        Circle()
                            .fill(Color(red: Double(preset.lighting.red) / 255, green: Double(preset.lighting.green) / 255,
                                        blue: Double(preset.lighting.blue) / 255))
                            .frame(width: 14, height: 14)
                        Text(preset.name)
                        Text(Effect.all.first { $0.id == preset.lighting.mode }?.name ?? "")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Uygula") { model.load(preset) }
                        Button(role: .destructive) { model.delete(preset) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Ad (ör. Oyun, Gece, Çalışma)", text: $presetName)
                        .onSubmit(savePreset)
                    Button("Şu anki ayarı kaydet", action: savePreset)
                }
            }
            Section {
                LabeledContent("Işıkları aç / kapat", value: "⌃ ⌥ ⌘ L")
            }
        }
        .formStyle(.grouped)
    }

    private func savePreset() {
        model.savePreset(named: presetName)
        presetName = ""
    }

    /// A minutes-after-midnight value as a time of day for the picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private static let swatches: [Int] = [0xFFFFFF, 0xFF2D2D, 0xFF8A00, 0xFFD60A, 0x30D158, 0x00C7BE, 0x0A84FF, 0x5E5CE6, 0xBF5AF2, 0xFF375F]
}
