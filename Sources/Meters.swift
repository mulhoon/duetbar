import Foundation

// Live metering. Glue streams opcode 0x68 at about 20 Hz to every connected
// client, so this only has to listen: no registration, no subscription.
//
// Payload is the device UID then 60 float32s, as 20 groups of three. The first
// value in each group is always exactly 0.0; the other two are the channel pair
// in dBFS, with -inf for silence.
//
// Which group is which was found by sweeping each input's gain and watching what
// moved, and by playing a tone of known amplitude.

struct MeterLevels: Equatable {
    var left: Double = -.infinity
    var right: Double = -.infinity

    static let silent = MeterLevels()

    /// These are decaying peak holds, and the decay isn't clamped: a channel left
    /// silent walks off to -200 dB and beyond. Treat anything under the floor as
    /// silence rather than trying to plot it.
    var peak: Double { max(left, right) }
}

struct MeterSet: Equatable {
    var speaker = MeterLevels.silent
    var headphones = MeterLevels.silent
    var input1 = MeterLevels.silent
    var input2 = MeterLevels.silent

    /// Group indices within the meter frame.
    static let speakerGroup = 6
    static let headphoneGroup = 7
    static let input1Group = 4
    static let input2Group = 5
}

/// Holds a connection open and reports meter frames while the panel is visible.
/// Stopped when the panel closes, so an idle app costs nothing.
final class MeterMonitor {
    private let queue = DispatchQueue(label: "com.duetbar.meters")
    private var running = false
    private var onUpdate: ((MeterSet) -> Void)?

    func start(_ handler: @escaping (MeterSet) -> Void) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            onUpdate = handler
            loop()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            onUpdate = nil
        }
    }

    private func loop() {
        guard running, let port = GlueService.discoverPort(),
              let connection = try? GlueConnection(port: port) else {
            // Nothing listening, or no device. Try again shortly rather than spin.
            queue.asyncAfter(deadline: .now() + 2) { [self] in if running { loop() } }
            return
        }
        connection.greet()

        connection.readFrames(while: { [self] in running }) { [self] body in
            guard body.first == 0x68, let set = MeterMonitor.decode(body) else { return }
            let handler = onUpdate
            DispatchQueue.main.async { handler?(set) }
        }

        // Stream ended. If we're still wanted, reconnect.
        queue.asyncAfter(deadline: .now() + 1) { [self] in if running { loop() } }
    }

    static func decode(_ body: [UInt8]) -> MeterSet? {
        // Skip the opcode header, then the null terminated device UID.
        guard let uidEnd = body[4...].firstIndex(of: 0) else { return nil }
        let start = uidEnd + 1
        let count = (body.count - start) / 4
        guard count >= 24 else { return nil }

        func value(_ index: Int) -> Double {
            let offset = start + index * 4
            let bits = UInt32(body[offset])
                | UInt32(body[offset + 1]) << 8
                | UInt32(body[offset + 2]) << 16
                | UInt32(body[offset + 3]) << 24
            return Double(Float(bitPattern: bits))
        }

        func group(_ index: Int) -> MeterLevels {
            MeterLevels(left: value(index * 3 + 1), right: value(index * 3 + 2))
        }

        var set = MeterSet()
        set.input1 = group(MeterSet.input1Group)
        set.input2 = group(MeterSet.input2Group)
        set.speaker = group(MeterSet.speakerGroup)
        set.headphones = group(MeterSet.headphoneGroup)
        return set
    }
}
