import SwiftUI

// The panel stands in for the Duet's own display, so the level readouts are the
// hero and everything else stays quiet. Outputs sit in their own cards, inputs
// run beneath them as a lighter list.

// MARK: - Model

@MainActor
final class DuetModel: ObservableObject {
    @Published var state = DeviceState()
    @Published var connected = false
    @Published var meters = MeterSet()

    private let meterMonitor = MeterMonitor()

    /// Set while a slider is being dragged, so polling can't yank it away.
    private var editing = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        registerHotKeys()
    }

    /// Hotkeys drive the speakers, since those are the ones you can't reach.
    private func registerHotKeys() {
        let manager = HotKeyManager.shared
        manager.register(.muteSpeakers) { [weak self] in self?.toggleMute(speaker: true) }
        manager.register(.dimSpeakers) { [weak self] in self?.toggleDim(speaker: true) }
        manager.register(.volumeUp) { [weak self] in
            self?.nudgeGain(speaker: true, by: hotKeyVolumeStep)
        }
        manager.register(.volumeDown) { [weak self] in
            self?.nudgeGain(speaker: true, by: -hotKeyVolumeStep)
        }
    }

    func refresh() {
        guard !editing else { return }
        Task.detached(priority: .utility) {
            let fresh = GlueService.read()
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let fresh else { self.connected = false; return }
                self.connected = true
                if !self.editing { self.state = fresh }
            }
        }
    }

    /// Meters only run while the panel is open, so an idle app costs nothing.
    func startMeters() {
        meterMonitor.start { [weak self] set in self?.meters = set }
    }

    func stopMeters() {
        meterMonitor.stop()
        meters = MeterSet()
    }

    func beginEditing() { editing = true }
    func endEditing() {
        editing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    // Outputs
    func output(speaker: Bool) -> OutputState { speaker ? state.speaker : state.headphones }

    func setGain(speaker: Bool, _ dB: Double) {
        if speaker { state.speaker.gain = dB } else { state.headphones.gain = dB }
        GlueService.setGain(speaker: speaker, dB)
    }

    func nudgeGain(speaker: Bool, by delta: Double) {
        setGain(speaker: speaker, min(max(output(speaker: speaker).gain + delta, -64), 0))
    }

    func toggleMute(speaker: Bool) {
        let value = !output(speaker: speaker).muted
        if speaker { state.speaker.muted = value } else { state.headphones.muted = value }
        GlueService.setMuted(speaker: speaker, value)
    }

    func toggleDim(speaker: Bool) {
        let value = !output(speaker: speaker).dimmed
        if speaker { state.speaker.dimmed = value } else { state.headphones.dimmed = value }
        GlueService.setDimmed(speaker: speaker, value)
    }

    func toggleMono(speaker: Bool) {
        let value = !output(speaker: speaker).mono
        if speaker { state.speaker.mono = value } else { state.headphones.mono = value }
        GlueService.setMono(speaker: speaker, value)
    }

    // Inputs
    func setSource(_ index: Int, _ source: InputSource) {
        state.inputs[index].source = source
        GlueService.setSource(input: index, source)
    }

    func setInputGain(_ index: Int, _ dB: Double) {
        let source = state.inputs[index].source
        guard source.hasGain else { return }
        if source == .mic { state.inputs[index].micGain = dB } else { state.inputs[index].instGain = dB }
        GlueService.setActiveGain(input: index, source: source, dB: dB)
    }

    func toggleSoftLimit(_ index: Int) {
        state.inputs[index].softLimit.toggle()
        GlueService.setSoftLimit(input: index, state.inputs[index].softLimit)
    }

    func togglePhase(_ index: Int) {
        state.inputs[index].phaseInverted.toggle()
        GlueService.setPhase(input: index, state.inputs[index].phaseInverted)
    }

    func togglePhantom(_ index: Int) {
        state.inputs[index].phantom.toggle()
        GlueService.setPhantom(input: index, state.inputs[index].phantom)
    }

    func setSampleRate(_ hz: Int) {
        state.sampleRate = hz
        GlueService.setSampleRate(hz)
    }

    // Menu bar. Follows the speakers, since that's the output you can't see.
    var barLabel: String {
        guard connected else { return "—" }
        if state.speaker.muted { return "muted" }
        return String(format: "%.0f", state.speaker.gain)
    }

    var barSymbol: String {
        guard connected else { return "speaker.slash" }
        if state.speaker.muted { return "speaker.slash.fill" }
        if state.speaker.dimmed || state.speaker.gain < -50 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - Pieces

/// The system slider already carries the Liquid Glass treatment, keyboard arrows
/// and accessibility, so use it rather than reimplementing a knob. `.large` keeps
/// it easy to grab.
struct LevelSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var enabled = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            .controlSize(.large)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
    }
}

/// A real segmented picker, which the system renders as glass on macOS 26.
struct SourcePicker: View {
    let selection: InputSource
    let onSelect: (InputSource) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { selection }, set: onSelect)) {
            ForEach(InputSource.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// Glass when it's off, prominent glass when it's on. Both are system styles, so
/// the highlight, press feedback and vibrancy come from macOS rather than from us.
struct PillToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            if isOn {
                button.buttonStyle(.glassProminent).controlSize(.large)
            } else {
                button.buttonStyle(.glass).controlSize(.large)
            }
        } else {
            button
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.07))
                )
                .foregroundStyle(isOn ? Color.white : Color.secondary)
        }
    }

    private var button: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
        }
    }
}

/// Sections are separated by hairlines rather than boxed, so the panel reads as
/// one surface. The buttons keep their own glass, since those are real controls.

/// One bar for the level, with the peak hold marked by a thin line. Deliberately
/// quiet: it should read as movement in the corner of your eye, not as a feature.
struct MeterBar: View {
    let levels: MeterLevels

    private let height: CGFloat = 5
    private let markerWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let peak = fraction(levels.peak)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(colour(levels.level))
                    .frame(width: width * fraction(levels.level))
                if peak > 0 {
                    Capsule()
                        .fill(Color.red)
                        .frame(width: markerWidth)
                        .offset(x: min(max(width * peak - markerWidth / 2, 0),
                                       width - markerWidth))
                }
            }
        }
        .frame(height: height)
    }

    /// Floor to 0 dBFS across the width. Silence arrives as -inf.
    private func fraction(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        let floor = MeterLevels.floor
        return min(max((decibels - floor) / -floor, 0), 1)
    }

    private func colour(_ decibels: Double) -> Color {
        if decibels >= -0.5 { return .red }
        if decibels >= -6 { return .orange }
        return .accentColor
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// One output, in its own card.
struct OutputCard: View {
    let title: String
    let state: OutputState
    let meters: MeterLevels
    let onGain: (Double) -> Void
    let onEditing: (Bool) -> Void
    let onMute: () -> Void
    let onDim: () -> Void
    let onMono: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SectionLabel(text: title)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", state.gain))
                        .font(.system(size: 30, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(state.muted ? .tertiary : .primary)
                    Text("dB")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            LevelSlider(value: Binding(get: { state.gain }, set: onGain),
                        range: -64...0,
                        onEditingChanged: onEditing)

            MeterBar(levels: meters)

            HStack(spacing: 8) {
                PillToggle(title: "Mute", isOn: state.muted, action: onMute)
                PillToggle(title: "Dim", isOn: state.dimmed, action: onDim)
                PillToggle(title: "Mono", isOn: state.mono, action: onMono)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Panel

struct ControlPanel: View {
    @ObservedObject var model: DuetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OutputCard(title: "Speakers",
                       state: model.state.speaker,
                       meters: model.meters.speaker,
                       onGain: { model.setGain(speaker: true, $0) },
                       onEditing: { $0 ? model.beginEditing() : model.endEditing() },
                       onMute: { model.toggleMute(speaker: true) },
                       onDim: { model.toggleDim(speaker: true) },
                       onMono: { model.toggleMono(speaker: true) })

            Divider()

            OutputCard(title: "Headphones",
                       state: model.state.headphones,
                       meters: model.meters.headphones,
                       onGain: { model.setGain(speaker: false, $0) },
                       onEditing: { $0 ? model.beginEditing() : model.endEditing() },
                       onMute: { model.toggleMute(speaker: false) },
                       onDim: { model.toggleDim(speaker: false) },
                       onMono: { model.toggleMono(speaker: false) })

            Divider()

            inputSection(0)

            Divider()

            inputSection(1)

            Divider()

            sampleRateRow

            Divider()

            shortcutsRow

            Divider()

            footer
        }
        .padding(18)
        .frame(width: 340)
        .disabled(!model.connected)
        .overlay { if !model.connected { disconnected } }
        .onAppear { model.startMeters() }
        .onDisappear { model.stopMeters() }
    }

    private func inputSection(_ index: Int) -> some View {
        let input = model.state.inputs[index]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 7) {
                SectionLabel(text: "Input \(index + 1)")
                Spacer(minLength: 8)
                SourcePicker(selection: input.source,
                             onSelect: { model.setSource(index, $0) })
                    .frame(width: 168)
            }

            HStack(spacing: 14) {
                LevelSlider(value: Binding(get: { input.activeGain ?? 0 },
                                           set: { model.setInputGain(index, $0) }),
                            range: 0...input.source.maxGain,
                            enabled: input.source.hasGain,
                            onEditingChanged: { $0 ? model.beginEditing() : model.endEditing() })

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if let gain = input.activeGain {
                        Text(String(format: "%.1f", gain))
                            .font(.system(size: 21, weight: .regular))
                            .monospacedDigit()
                        Text("dB")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("line")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 74, alignment: .trailing)
            }

            MeterBar(levels: index == 0 ? model.meters.input1 : model.meters.input2)

            HStack(spacing: 8) {
                // The hardware only has phantom on a mic input, so don't offer a
                // control that would do nothing in the other three modes.
                if input.source == .mic {
                    PillToggle(title: "48V", isOn: input.phantom) { model.togglePhantom(index) }
                }
                PillToggle(title: "Soft Limit", isOn: input.softLimit) { model.toggleSoftLimit(index) }
                PillToggle(title: "Phase Invert", isOn: input.phaseInverted) { model.togglePhase(index) }
                Spacer(minLength: 0)
            }
        }
    }

    private var sampleRateRow: some View {
        HStack {
            SectionLabel(text: "Sample rate")
            Spacer()
            Picker("", selection: Binding(get: { model.state.sampleRate },
                                          set: { model.setSampleRate($0) })) {
                ForEach(GlueService.sampleRates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 112)
        }
    }

    static func rateLabel(_ hz: Int) -> String {
        let k = Double(hz) / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    /// Listed once so they're learnable. They act on the speakers.
    private var shortcutsRow: some View {
        let blocked = HotKeyManager.shared.unavailable.map(\.id)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(HotKeySpec.all, id: \.id) { spec in
                HStack {
                    Text(spec.name)
                        .font(.system(size: 11))
                        .foregroundStyle(blocked.contains(spec.id) ? .tertiary : .secondary)
                    Spacer()
                    Text(blocked.contains(spec.id) ? "in use elsewhere" : spec.display)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("About") { showAbout() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var disconnected: some View {
        VStack(spacing: 7) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 22, weight: .light))
            Text("No Duet found")
                .font(.system(size: 13, weight: .medium))
            Text("Check it's plugged in and switched on.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

// MARK: - About

/// Uses macOS's own About window rather than a hand-built one, so it matches
/// every other app and gets the link handling for free.
func showAbout() {
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center

    let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: centred,
    ]

    let credits = NSMutableAttributedString()
    credits.append(NSAttributedString(
        string: "Control an Apogee Duet 2 from the menu bar.\n\nby Nic Mulvaney\n",
        attributes: body))
    credits.append(NSAttributedString(
        string: "github.com/mulhoon/duetbar",
        attributes: [
            .link: URL(string: "https://github.com/mulhoon/duetbar")!,
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: centred,
        ]))
    credits.append(NSAttributedString(
        string: "\n\nUnofficial. Not affiliated with Apogee Electronics.",
        attributes: body))

    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "Duetbar",
        .applicationVersion: "0.1.0",
        .credits: credits,
    ])
}

// MARK: - App

@main
struct DuetbarApp: App {
    @StateObject private var model = DuetModel()

    // If the message builder stops matching bytes captured from Control 2, say so
    // rather than sending malformed messages to a root service.
    private let builderOK = selfCheckPassed()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            if builderOK {
                HStack(spacing: 3) {
                    Image(systemName: model.barSymbol)
                    Text(model.barLabel).monospacedDigit()
                }
            } else {
                Text("Duetbar: self-check failed")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
