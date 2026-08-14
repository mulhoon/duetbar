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

    func nudgeInputGain(_ index: Int, by delta: Double) {
        let source = state.inputs[index].source
        guard source.hasGain else { return }
        let current = source == .mic ? state.inputs[index].micGain : state.inputs[index].instGain
        setInputGain(index, min(max(current + delta, 0), source.maxGain))
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

/// Shared meter scale and colours, matching Apogee Control: saturated green to
/// -12, pale green to 0, red above. The scale is not linear; the top few dB get
/// far more room, taken from Control's own tick spacing.
enum MeterScale {
    static let strongGreen = Color(red: 0.04, green: 0.76, blue: 0.24)
    static let paleGreen = Color(red: 0.62, green: 0.88, blue: 0.66)
    static let over = Color(red: 1.0, green: 0.16, blue: 0.12)

    static let anchors: [(db: Double, at: Double)] = [
        (-60, 0.00), (-40, 0.154), (-24, 0.327), (-12, 0.577), (-6, 0.808), (0, 1.00),
    ]

    static let stops: [Gradient.Stop] = [
        .init(color: strongGreen, location: 0.0),
        .init(color: strongGreen, location: 0.577),
        .init(color: paleGreen, location: 0.577),
        .init(color: paleGreen, location: 0.955),
        .init(color: over, location: 0.955),
        .init(color: over, location: 1.0),
    ]

    static func fraction(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        if decibels <= anchors[0].db { return 0 }
        if decibels >= 0 { return 1 }
        for index in 1..<anchors.count {
            let low = anchors[index - 1], high = anchors[index]
            if decibels <= high.db {
                let t = (decibels - low.db) / (high.db - low.db)
                return low.at + t * (high.at - low.at)
            }
        }
        return 1
    }
}

/// Vertical meter with the peak hold as a thin line that gets pushed up by the level.
struct VerticalMeter: View {
    let levels: MeterLevels

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let peak = MeterScale.fraction(levels.peak)
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.10))

                Rectangle()
                    .fill(LinearGradient(gradient: Gradient(stops: MeterScale.stops),
                                         startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: height * MeterScale.fraction(levels.level))
                    }

                if peak > 0 {
                    Rectangle()
                        .fill(MeterScale.over)
                        .frame(height: 2)
                        .offset(y: -min(max(height * peak - 1, 0), height - 2))
                }
            }
        }
        .frame(width: 9)
    }
}

/// A dial. Arc track with the value filled in, and a pointer.
///
/// Dragging is vertical, with the whole range covering about 160 points of
/// travel. Hold shift for fine adjustment, since a 54 point dial has too little
/// travel to set a 75 dB range precisely otherwise.
struct Dial: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var enabled = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Reports a change in dB rather than an absolute, because a monitor closure
    /// captures `value` at hover time and never sees later updates.
    var onScroll: (Double) -> Void = { _ in }

    @State private var dragStart: Double?
    @State private var hovering = false
    @State private var scrollMonitor: Any?
    @State private var scrollIdle: Timer?

    private let diameter: CGFloat = 54
    private let lineWidth: CGFloat = 3.5
    /// Degrees of travel, leaving a gap at the bottom.
    private let sweep: Double = 270

    private var pointerLength: CGFloat { diameter / 2 }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        ZStack {
            arc(to: 1).stroke(Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(to: fraction).stroke(Color.primary.opacity(enabled ? 0.85 : 0.25),
                                     style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Same thickness as the arc, running from the exact centre out to
            // the arc's centreline so the two meet rather than leaving a gap.
            Capsule()
                .fill(Color.primary.opacity(enabled ? 0.85 : 0.25))
                .frame(width: lineWidth, height: pointerLength)
                .offset(y: -pointerLength / 2)
                .rotationEffect(.degrees(225 + fraction * sweep))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .opacity(enabled ? 1 : 0.5)
        .onHover { inside in
            hovering = inside
            inside ? startScrollMonitor() : stopScrollMonitor()
        }
        .onDisappear { stopScrollMonitor() }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    guard enabled else { return }
                    if dragStart == nil {
                        dragStart = value
                        onEditingChanged(true)
                    }
                    let span = range.upperBound - range.lowerBound
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 4.0 : 1.0
                    let delta = -drag.translation.height / (160 * fine) * span
                    value = min(max((dragStart ?? value) + delta, range.lowerBound),
                                range.upperBound)
                }
                .onEnded { _ in
                    guard dragStart != nil else { return }
                    dragStart = nil
                    onEditingChanged(false)
                }
        )
    }

    /// Scroll to adjust, but only while the pointer is over this dial. A local
    /// monitor is used rather than an overlaid NSView, because an NSView on top
    /// would swallow the drag gesture underneath it.
    private func startScrollMonitor() {
        guard enabled, scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            var dy = event.scrollingDeltaY
            if event.isDirectionInvertedFromDevice { dy = -dy }

            // Trackpads send many small deltas; a wheel sends a few large ones.
            let perUnit = event.hasPreciseScrollingDeltas ? 0.04 : 0.5
            let fine = event.modifierFlags.contains(.shift) ? 0.25 : 1.0
            let step = -dy * perUnit * fine     // scroll up raises the level
            guard step != 0 else { return nil }

            if dragStart == nil { onEditingChanged(true) }
            onScroll(step)

            // Let polling resume once scrolling stops.
            scrollIdle?.invalidate()
            scrollIdle = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                if dragStart == nil { onEditingChanged(false) }
            }
            return nil          // consume, so nothing behind scrolls
        }
    }

    private func stopScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrollIdle?.invalidate()
        scrollIdle = nil
    }

    private func arc(to end: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: (sweep / 360) * end)
            .rotation(.degrees(90 + (360 - sweep) / 2))
    }
}

/// Colour of a pill when it's on. Fill and text travel together so contrast
/// stays right, including for the near-black one which needs light text.
struct PillTint {
    let fill: Color
    let text: Color

    static let orange = PillTint(fill: Color(red: 0.95, green: 0.53, blue: 0.12), text: .white)
    static let turquoise = PillTint(fill: Color(red: 0.08, green: 0.73, blue: 0.64), text: .white)
    /// Black in light mode, white in dark, with the text inverted to match.
    static let ink = PillTint(fill: .primary, text: Color(nsColor: .textBackgroundColor))
}

/// One surface for every pill, so the buttons and the menu are the same height
/// and width by construction rather than by two sets of numbers agreeing.
private struct PillSurface: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
            )
    }
}

private extension View {
    func pillSurface(_ fill: Color) -> some View { modifier(PillSurface(fill: fill)) }
}

private let pillOffFill = Color.primary.opacity(0.09)

struct PillToggle: View {
    let title: String
    let isOn: Bool
    var tint: PillTint = .orange
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isOn ? tint.text : Color.secondary)
                .pillSurface(isOn ? tint.fill : pillOffFill)
        }
        .buttonStyle(.plain)
    }
}

/// The input source selector.
///
/// This is a plain `Button` that pops an `NSMenu`, not a SwiftUI `Menu`. SwiftUI
/// menus carry their own minimum height and intrinsic width on macOS and ignore
/// the label's frame, so they can never line up with the pills beside them. Using
/// the same primitive as the pills makes them match by construction.
struct PillMenu: View {
    let selection: InputSource
    let onSelect: (InputSource) -> Void

    var body: some View {
        Button {
            present()
        } label: {
            Text(selection.label)
                .foregroundStyle(.secondary)
                .pillSurface(pillOffFill)
        }
        .buttonStyle(.plain)
    }

    private func present() {
        let menu = NSMenu()
        for source in InputSource.allCases {
            let item = NSMenuItem(title: source.label,
                                  action: #selector(SourceMenuTarget.pick(_:)),
                                  keyEquivalent: "")
            item.target = SourceMenuTarget.shared
            item.representedObject = source.rawValue
            item.state = source == selection ? .on : .off
            menu.addItem(item)
        }
        SourceMenuTarget.shared.handler = onSelect

        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

/// NSMenu needs an Objective-C target, which a SwiftUI view can't be.
final class SourceMenuTarget: NSObject {
    static let shared = SourceMenuTarget()
    var handler: ((InputSource) -> Void)?

    @objc func pick(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let source = InputSource(rawValue: raw) else { return }
        handler?(source)
    }
}

/// No SF Symbol exists for an XLR connector, so draw one: the shell with three
/// pins in a triangle.
struct XLRIcon: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 1.2)
            // Pins left, right and bottom.
            ForEach([90.0, 180.0, 270.0], id: \.self) { angle in
                Circle()
                    .frame(width: 3.2, height: 3.2)
                    .offset(y: -4.4)
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: 17, height: 17)
    }
}

/// What's plugged into the input, at a glance.
struct SourceIcon: View {
    let source: InputSource

    var body: some View {
        Group {
            switch source {
            case .mic:
                Image(systemName: "music.mic").font(.system(size: 16))
            case .instrument:
                // There's no singular guitar symbol, only the pair.
                Image(systemName: "guitars").font(.system(size: 16))
            case .plus4, .minus10:
                XLRIcon()
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
    }
}

// MARK: - Channel strip

struct ChannelStrip<Controls: View>: View {
    let title: String
    let meters: MeterLevels
    let value: Double
    let range: ClosedRange<Double>
    var enabled = true
    var sourceIcon: InputSource? = nil
    let onValue: (Double) -> Void
    let onEditing: (Bool) -> Void
    var onScroll: (Double) -> Void = { _ in }
    @ViewBuilder var controls: Controls

    static var width: CGFloat { 92 }

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VerticalMeter(levels: meters)
                .frame(height: 144)
                .padding(.bottom, 8)
                .overlay(alignment: .topLeading) {
                    if let sourceIcon {
                        SourceIcon(source: sourceIcon).offset(x: -26)
                    }
                }

            Dial(value: Binding(get: { value }, set: onValue),
                 range: range,
                 enabled: enabled,
                 onEditingChanged: onEditing,
                 onScroll: onScroll)

            Text(enabled ? String(format: "%.1f", value) : "line")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(enabled ? .primary : .tertiary)

            VStack(spacing: 5) { controls }

            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
    }
}

// MARK: - Panel

struct ControlPanel: View {
    @ObservedObject var model: DuetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duetbar")
                .font(.system(size: 21, weight: .semibold))

            HStack(alignment: .top, spacing: 12) {
                inputStrip(0)
                inputStrip(1)
                outputStrip(speaker: false)
                outputStrip(speaker: true)
            }

            Divider()
            footer
        }
        .padding(16)
        .disabled(!model.connected)
        .overlay { if !model.connected { disconnected } }
        .onAppear { model.startMeters() }
        .onDisappear { model.stopMeters() }
    }

    private func inputStrip(_ index: Int) -> some View {
        let input = model.state.inputs[index]
        return ChannelStrip(
            title: "Input \(index + 1)",
            meters: index == 0 ? model.meters.input1 : model.meters.input2,
            value: input.activeGain ?? 0,
            range: 0...input.source.maxGain,
            enabled: input.source.hasGain,
            sourceIcon: input.source,
            onValue: { model.setInputGain(index, $0) },
            onEditing: { $0 ? model.beginEditing() : model.endEditing() },
            onScroll: { model.nudgeInputGain(index, by: $0) }
        ) {
            PillMenu(selection: input.source) { model.setSource(index, $0) }

            // Phantom only exists on a mic input, so don't offer a dead control.
            PillToggle(title: "48V", isOn: input.phantom, tint: .orange) {
                model.togglePhantom(index)
            }
                .opacity(input.source == .mic ? 1 : 0)
                .disabled(input.source != .mic)

            PillToggle(title: "Limit", isOn: input.softLimit, tint: .turquoise) {
                model.toggleSoftLimit(index)
            }
            PillToggle(title: "Phase", isOn: input.phaseInverted, tint: .ink) {
                model.togglePhase(index)
            }
        }
    }

    private func outputStrip(speaker: Bool) -> some View {
        let state = model.output(speaker: speaker)
        return ChannelStrip(
            title: speaker ? "Speakers" : "Headphones",
            meters: speaker ? model.meters.speaker : model.meters.headphones,
            value: state.gain,
            range: -64...0,
            onValue: { model.setGain(speaker: speaker, $0) },
            onEditing: { $0 ? model.beginEditing() : model.endEditing() },
            onScroll: { model.nudgeGain(speaker: speaker, by: $0) }
        ) {
            PillToggle(title: "Mute", isOn: state.muted, tint: .orange) {
                model.toggleMute(speaker: speaker)
            }
            PillToggle(title: "Dim", isOn: state.dimmed, tint: .turquoise) {
                model.toggleDim(speaker: speaker)
            }
            PillToggle(title: "Mono", isOn: state.mono, tint: .ink) {
                model.toggleMono(speaker: speaker)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { model.state.sampleRate },
                                          set: { model.setSampleRate($0) })) {
                ForEach(GlueService.sampleRates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: ChannelStrip<EmptyView>.width, alignment: .leading)

            Spacer()

            Button("About") { showAbout() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    static func rateLabel(_ hz: Int) -> String {
        let k = Double(hz) / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
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
        .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
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
