import Foundation
import Compression

// Client for the ApogeeGlue daemon, the background service that actually drives
// Apogee hardware. Control 2 is just another client of the same service, so both
// can run at once and see each other's changes.
//
// Wire format (JUCE InterprocessConnection, JUCE 7.0.12):
//   frame:   f2b49e2c | length (LE32) | payload
//   payload: [opcode][len][crc8 of first two][juce var marker][id x4][value][crc8]
//
// Every constant here was verified against captured Control 2 traffic.

enum Glue {
    static let magic: UInt32 = 0xf2b4_9e2c
    static let defaultPort: UInt16 = 53435
    static let hello = Data([0x21, 0x00, 0xbb, 0x00])

    static let opSetProperty: UInt8 = 0x03
    static let opFullTree: UInt8 = 0x66

    // JUCE var type markers, used as byte 3.
    static let markerInt: UInt8 = 1
    static let markerBool: UInt8 = 3
    static let markerDouble: UInt8 = 4
}

// MARK: - Properties

/// A property is addressed by a 32-bit ID: the Java-style string hash
/// (h = 31 * h + c, wrapping) of its path in Glue's tree, sent little endian.
/// The path starts with the device's uid, e.g.
/// `/dev/DuetII8100000000002119/hwout/hwout0/gain`, so the IDs differ for every
/// Duet and have to be worked out from the uid Glue reports, never hardcoded.
struct PropertyID {
    let path: String
    let marker: UInt8

    static let speakerGain  = PropertyID(path: "hwout/hwout0/gain", marker: Glue.markerDouble)
    static let speakerMute  = PropertyID(path: "hwout/hwout0/mute", marker: Glue.markerBool)
    static let speakerDim   = PropertyID(path: "hwout/hwout0/dim", marker: Glue.markerBool)
    static let speakerSum   = PropertyID(path: "hwout/hwout0/sum", marker: Glue.markerBool)
    static let speakerLevel = PropertyID(path: "hwout/hwout0/analogRefLevel", marker: Glue.markerInt)

    static let hpGain = PropertyID(path: "hwout/hwout1/gain", marker: Glue.markerDouble)
    static let hpMute = PropertyID(path: "hwout/hwout1/mute", marker: Glue.markerBool)
    static let hpDim  = PropertyID(path: "hwout/hwout1/dim", marker: Glue.markerBool)
    static let hpSum  = PropertyID(path: "hwout/hwout1/sum", marker: Glue.markerBool)

    static let sampleRate = PropertyID(path: "samplerate", marker: Glue.markerInt)

    static let in1Source    = PropertyID(path: "hwin/hwin0/analogRefLevel", marker: Glue.markerInt)
    static let in1MicGain   = PropertyID(path: "hwin/hwin0/micSettings/PreModelDuet/gain", marker: Glue.markerDouble)
    static let in1InstGain  = PropertyID(path: "hwin/hwin0/instSettings/PreModelDuet/gain", marker: Glue.markerDouble)
    static let in1SoftLimit = PropertyID(path: "hwin/hwin0/softLimit", marker: Glue.markerBool)
    static let in1Phase     = PropertyID(path: "hwin/hwin0/polarityInvert", marker: Glue.markerBool)
    static let in1Phantom   = PropertyID(path: "hwin/hwin0/micSettings/phantom", marker: Glue.markerBool)

    static let in2Source    = PropertyID(path: "hwin/hwin1/analogRefLevel", marker: Glue.markerInt)
    static let in2MicGain   = PropertyID(path: "hwin/hwin1/micSettings/PreModelDuet/gain", marker: Glue.markerDouble)
    static let in2InstGain  = PropertyID(path: "hwin/hwin1/instSettings/PreModelDuet/gain", marker: Glue.markerDouble)
    static let in2SoftLimit = PropertyID(path: "hwin/hwin1/softLimit", marker: Glue.markerBool)
    static let in2Phase     = PropertyID(path: "hwin/hwin1/polarityInvert", marker: Glue.markerBool)
    static let in2Phantom   = PropertyID(path: "hwin/hwin1/micSettings/phantom", marker: Glue.markerBool)

    /// The wire ID for this property on the device with `uid`.
    func bytes(uid: String) -> [UInt8] {
        bytes(continuing: pathHash("/dev/\(uid)/"))
    }

    /// Hashes the path on from a state that already covers the `/dev/<uid>/`
    /// prefix. Lets the self check reproduce captures without knowing their uid.
    func bytes(continuing state: UInt32) -> [UInt8] {
        withUnsafeBytes(of: pathHash(path, from: state).littleEndian) { Array($0) }
    }
}

func pathHash(_ text: String, from state: UInt32 = 0) -> UInt32 {
    text.utf8.reduce(state) { $0 &* 31 &+ UInt32($1) }
}

/// One picker per input covers both the connector and the reference level.
enum InputSource: Int, CaseIterable, Identifiable {
    case mic = 1, plus4 = 2, minus10 = 3, instrument = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .mic: return "Mic"
        case .plus4: return "+4"
        case .minus10: return "−10"
        case .instrument: return "Inst"
        }
    }

    /// Line inputs sit at a fixed reference level, so there is no gain to set.
    var hasGain: Bool { self == .mic || self == .instrument }

    /// The Duet's preamp tops out lower on the instrument input. Writing 66 to it
    /// came back as 65, so the ceiling is enforced here rather than surprising the user.
    var maxGain: Double { self == .mic ? 75 : 65 }
}

// MARK: - Checksums and framing

func crc8(_ bytes: [UInt8], poly: UInt8 = 0x07, initial: UInt8 = 0) -> UInt8 {
    var crc = initial
    for byte in bytes {
        crc ^= byte
        for _ in 0..<8 {
            crc = (crc & 0x80) != 0 ? (crc << 1) ^ poly : crc << 1
        }
    }
    return crc
}

func frame(_ payload: [UInt8]) -> Data {
    var out = Data()
    withUnsafeBytes(of: Glue.magic.littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
    out.append(contentsOf: payload)
    return out
}

/// Byte 1 counts from the marker onwards, and byte 2 is a CRC of the two bytes
/// before it, which makes the running CRC zero at that point.
func setPropertyMessage(_ id: PropertyID, idBytes: [UInt8], value: [UInt8]) -> [UInt8] {
    let body = [id.marker] + idBytes + value
    var head: [UInt8] = [Glue.opSetProperty, UInt8(body.count)]
    head.append(crc8(head))
    let message = head + body
    return message + [crc8(message)]
}

func boolValue(_ on: Bool) -> [UInt8] { [on ? 1 : 0] }
func intValue(_ value: Int) -> [UInt8] {
    withUnsafeBytes(of: Int32(value).littleEndian) { Array($0) }
}
func doubleValue(_ value: Double) -> [UInt8] {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
}

/// Rebuilds messages captured verbatim from Control 2 and compares them. An
/// off-by-one in the length field produces messages Glue silently ignores, so
/// this runs at launch rather than being a test we forget. The captures came
/// from another Duet, so the hash starts from that device's prefix state.
func selfCheckPassed() -> Bool {
    let captured: UInt32 = 0x89fe_3e27
    func message(_ id: PropertyID, _ value: [UInt8]) -> [UInt8] {
        setPropertyMessage(id, idBytes: id.bytes(continuing: captured), value: value)
    }
    let cases: [([UInt8], String)] = [
        (message(.speakerMute, boolValue(true)),  "03062d03c0bfb2a10158"),
        (message(.speakerDim,  boolValue(true)),  "03062d0301469a91012b"),
        (message(.speakerSum,  boolValue(true)),  "03062d03c47f9a910196"),
        (message(.speakerLevel, intValue(3)),     "03090001a87cf0c60300000089"),
        (message(.speakerGain, doubleValue(-40.058)), "030d1c0426b9afa18195438b6c0744c07b"),
    ]
    return cases.allSatisfy { built, expected in
        built.map { String(format: "%02x", $0) }.joined() == expected
    }
}

// MARK: - JUCE ValueTree decoding

struct TreeNode {
    var type: String
    var properties: [String: Any]
    var children: [TreeNode]

    func firstNode(ofType wanted: String) -> TreeNode? {
        if type == wanted { return self }
        for child in children {
            if let found = child.firstNode(ofType: wanted) { return found }
        }
        return nil
    }

    func child(_ wanted: String) -> TreeNode? { children.first { $0.type == wanted } }

    /// Glue is inconsistent about types: the same logical flag arrives as a bool
    /// on one node and the string "0" on another, so accept both.
    func flag(_ name: String) -> Bool? {
        switch properties[name] {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as String: return value != "0" && !value.isEmpty
        default: return nil
        }
    }

    func number(_ name: String) -> Double? {
        switch properties[name] {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as String: return Double(value)
        default: return nil
        }
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var position = 0

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw GlueError.truncated }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard position + count <= bytes.count else { throw GlueError.truncated }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    mutating func string() throws -> String {
        guard let end = bytes[position...].firstIndex(of: 0) else { throw GlueError.truncated }
        defer { position = end + 1 }
        return String(decoding: bytes[position..<end], as: UTF8.self)
    }

    mutating func compressedInt() throws -> Int {
        let header = try byte()
        let raw = try read(Int(header & 0x7f))
        var value = 0
        for (index, part) in raw.enumerated() { value |= Int(part) << (8 * index) }
        return (header & 0x80) != 0 ? -value : value
    }

    mutating func variant() throws -> Any? {
        let length = try compressedInt()
        if length == 0 { return nil }
        let start = position
        let marker = try byte()
        var result: Any?
        switch marker {
        case 1: result = Int(Int32(bitPattern: UInt32(littleEndianFrom: try read(4))))
        case 2: result = true
        case 3: result = false
        case 4: result = Double(bitPattern: UInt64(littleEndianFrom: try read(8)))
        case 5: result = try string()
        case 6: result = Int(bitPattern: UInt(UInt64(littleEndianFrom: try read(8))))
        default: result = nil
        }
        position = start + length
        return result
    }

    mutating func tree() throws -> TreeNode {
        let type = try string()
        var properties: [String: Any] = [:]
        for _ in 0..<(try compressedInt()) {
            let name = try string()
            properties[name] = try variant()
        }
        var children: [TreeNode] = []
        for _ in 0..<(try compressedInt()) { children.append(try tree()) }
        return TreeNode(type: type, properties: properties, children: children)
    }
}

private extension UInt32 {
    init(littleEndianFrom bytes: [UInt8]) {
        self = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}

private extension UInt64 {
    init(littleEndianFrom bytes: [UInt8]) {
        self = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
}

enum GlueError: Error { case truncated, noDaemon }

/// Glue compresses tree payloads with zlib. Apple's Compression framework speaks
/// raw DEFLATE, so skip the two byte zlib header and let it ignore the trailer.
private func inflate(_ body: [UInt8]) -> [UInt8]? {
    guard body.count > 2 else { return nil }
    for index in 0..<min(body.count - 1, 48) {
        guard body[index] == 0x78,
              [0x01, 0x5e, 0x9c, 0xda].contains(body[index + 1]) else { continue }
        let deflated = Array(body[(index + 2)...])
        var capacity = 256 * 1024
        for _ in 0..<4 {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let written = deflated.withUnsafeBufferPointer { source in
                compression_decode_buffer(destination, capacity,
                                          source.baseAddress!, source.count,
                                          nil, COMPRESSION_ZLIB)
            }
            if written > 0 && written < capacity {
                return Array(UnsafeBufferPointer(start: destination, count: written))
            }
            capacity *= 4
        }
    }
    return nil
}

// MARK: - Connection

final class GlueConnection {
    private var socket: Int32 = -1
    static var cachedPort: UInt16?

    init(port: UInt16) throws {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw GlueError.noDaemon }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(socket); socket = -1
            throw GlueError.noDaemon
        }
    }

    deinit { if socket >= 0 { close(socket) } }

    @discardableResult
    func send(_ data: Data) -> Bool {
        let sent = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, data.count, 0) }
        return sent == data.count
    }

    func greet() { send(frame(Array(Glue.hello))) }

    /// Streams every frame to `handler` until `condition` goes false or the
    /// socket closes. Used for meters, which never stop arriving.
    func readFrames(while condition: () -> Bool, handler: ([UInt8]) -> Void) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)

        while condition() {
            let received = recv(socket, &chunk, chunk.count, 0)
            if received <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return
            }
            buffer.append(contentsOf: chunk[0..<received])

            var offset = 0
            while offset + 8 <= buffer.count {
                guard UInt32(littleEndianFrom: Array(buffer[offset..<(offset + 4)])) == Glue.magic
                else { return }
                let length = Int(UInt32(littleEndianFrom: Array(buffer[(offset + 4)..<(offset + 8)])))
                guard offset + 8 + length <= buffer.count else { break }
                handler(Array(buffer[(offset + 8)..<(offset + 8 + length)]))
                offset += 8 + length
            }
            if offset > 0 { buffer.removeFirst(offset) }
        }
    }

    /// Reads until a full-tree message satisfying `matching` arrives, or the
    /// deadline passes. Glue streams meter data forever, so an unbounded drain
    /// never returns.
    func awaitTree(timeout: TimeInterval = 3,
                   matching predicate: ((TreeNode) -> Bool)? = nil) -> TreeNode? {
        var buffer = [UInt8]()
        var lastSeen: TreeNode?
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 65536)

        while Date() < deadline {
            let received = recv(socket, &chunk, chunk.count, 0)
            if received <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<received])

            var offset = 0
            while offset + 8 <= buffer.count {
                guard UInt32(littleEndianFrom: Array(buffer[offset..<(offset + 4)])) == Glue.magic else {
                    return nil
                }
                let length = Int(UInt32(littleEndianFrom: Array(buffer[(offset + 4)..<(offset + 8)])))
                guard offset + 8 + length <= buffer.count else { break }
                let body = Array(buffer[(offset + 8)..<(offset + 8 + length)])
                if body.first == Glue.opFullTree, let raw = inflate(body) {
                    var reader = ByteReader(bytes: raw)
                    if let tree = try? reader.tree() {
                        guard let predicate else { return tree }
                        if predicate(tree) { return tree }
                        lastSeen = tree
                    }
                }
                offset += 8 + length
            }
            if offset > 0 { buffer.removeFirst(offset) }
        }
        return predicate == nil ? lastSeen : nil
    }
}

// MARK: - Device state

struct OutputState {
    var gain: Double = -64
    var muted = false
    var dimmed = false
    var mono = false
}

struct InputState {
    var source: InputSource = .mic
    var micGain: Double = 0
    var instGain: Double = 0
    var softLimit = false
    var phaseInverted = false
    /// 48V. Only meaningful on a mic input; the hardware has no phantom elsewhere.
    var phantom = false

    /// The gain the hardware is currently using, or nil at a fixed line level.
    var activeGain: Double? {
        switch source {
        case .mic: return micGain
        case .instrument: return instGain
        default: return nil
        }
    }
}

struct DeviceState {
    var speaker = OutputState()
    var headphones = OutputState()
    var inputs: [InputState] = [InputState(), InputState()]
    var sampleRate: Int = 48000
}

// MARK: - Service

enum GlueService {
    static let writer = GlueWriter()

    static func discoverPort() -> UInt16? {
        if let cached = GlueConnection.cachedPort { return cached }
        var candidates: [UInt16] = [Glue.defaultPort]
        candidates.append(contentsOf: listeningPorts().filter { $0 != Glue.defaultPort })

        for port in candidates {
            guard let connection = try? GlueConnection(port: port) else { continue }
            connection.greet()
            if connection.awaitTree(timeout: 1.5) != nil {
                GlueConnection.cachedPort = port
                return port
            }
        }
        return nil
    }

    private static func listeningPorts() -> [UInt16] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-an", "-p", "tcp"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.contains("LISTEN") else { return nil }
            return line.split(separator: " ").compactMap { part -> UInt16? in
                guard part.hasPrefix("127.0.0.1.") else { return nil }
                return UInt16(part.dropFirst("127.0.0.1.".count))
            }.first
        }
    }

    static func read() -> DeviceState? {
        guard let port = discoverPort(),
              let connection = try? GlueConnection(port: port) else { return nil }
        connection.greet()
        // The apps tree and the device tree are both full-tree messages, so ask
        // for the one that actually has hardware in it.
        guard let tree = connection.awaitTree(matching: { $0.firstNode(ofType: "hwout0") != nil })
        else { return nil }

        var state = DeviceState()
        if let node = tree.firstNode(ofType: "hwout0") {
            state.speaker = OutputState(gain: node.number("gain") ?? -64,
                                        muted: node.flag("mute") ?? false,
                                        dimmed: node.flag("dim") ?? false,
                                        mono: node.flag("sum") ?? false)
        }
        if let node = tree.firstNode(ofType: "hwout1") {
            state.headphones = OutputState(gain: node.number("gain") ?? -64,
                                           muted: node.flag("mute") ?? false,
                                           dimmed: node.flag("dim") ?? false,
                                           mono: node.flag("sum") ?? false)
        }
        for (index, type) in ["hwin0", "hwin1"].enumerated() {
            guard let node = tree.firstNode(ofType: type) else { continue }
            var input = InputState()
            input.source = InputSource(rawValue: Int(node.number("analogRefLevel") ?? 1)) ?? .mic
            input.softLimit = node.flag("softLimit") ?? false
            input.phaseInverted = node.flag("polarityInvert") ?? false
            input.micGain = node.child("micSettings")?.children.first?.number("gain") ?? 0
            input.instGain = node.child("instSettings")?.children.first?.number("gain") ?? 0
            input.phantom = node.child("micSettings")?.flag("phantom") ?? false
            state.inputs[index] = input
        }
        if let device = tree.firstNode(ofType: "dev")?.children.first {
            state.sampleRate = Int(device.number("samplerate") ?? 48000)
            writer.deviceUID = device.type
        }
        return state
    }

    // Outputs
    static func setGain(speaker: Bool, _ dB: Double) {
        let clamped = min(max(dB, -64), 0)
        writer.write(speaker ? .speakerGain : .hpGain, value: doubleValue(clamped))
    }
    static func setMuted(speaker: Bool, _ on: Bool) {
        writer.write(speaker ? .speakerMute : .hpMute, value: boolValue(on))
    }
    static func setDimmed(speaker: Bool, _ on: Bool) {
        writer.write(speaker ? .speakerDim : .hpDim, value: boolValue(on))
    }
    static func setMono(speaker: Bool, _ on: Bool) {
        writer.write(speaker ? .speakerSum : .hpSum, value: boolValue(on))
    }

    // Inputs
    static func setSource(input: Int, _ source: InputSource) {
        writer.write(input == 0 ? .in1Source : .in2Source, value: intValue(source.rawValue))
    }
    static func setSoftLimit(input: Int, _ on: Bool) {
        writer.write(input == 0 ? .in1SoftLimit : .in2SoftLimit, value: boolValue(on))
    }
    static func setPhase(input: Int, _ on: Bool) {
        writer.write(input == 0 ? .in1Phase : .in2Phase, value: boolValue(on))
    }
    static func setPhantom(input: Int, _ on: Bool) {
        writer.write(input == 0 ? .in1Phantom : .in2Phantom, value: boolValue(on))
    }

    /// Rates the Duet 2 supports. Changing this restarts the audio clock, so
    /// anything playing will glitch briefly.
    static let sampleRates = [44100, 48000, 88200, 96000, 176400, 192000]

    static func setSampleRate(_ hz: Int) {
        guard sampleRates.contains(hz) else { return }
        writer.write(.sampleRate, value: intValue(hz))
    }

    /// Writes the gain for the mode the input is *currently* in.
    ///
    /// Writing the other mode's gain ID overwrites both stored values, silently
    /// destroying the setting you weren't touching. There is no safe way to set
    /// an inactive mode's gain, so this only ever writes the active one and the
    /// caller cannot ask for anything else.
    static func setActiveGain(input: Int, source: InputSource, dB: Double) {
        guard source.hasGain else { return }
        let clamped = min(max(dB, 0), source.maxGain)
        let id: PropertyID
        switch (input, source) {
        case (0, .mic): id = .in1MicGain
        case (0, _):    id = .in1InstGain
        case (_, .mic): id = .in2MicGain
        default:        id = .in2InstGain
        }
        writer.write(id, value: doubleValue(clamped))
    }
}

/// Holds one connection open for writes. Opening a fresh socket per message costs
/// about half a second, which is fine for a toggle and far too slow for dragging
/// a slider. Reconnects by itself if Glue restarts.
final class GlueWriter {
    private var connection: GlueConnection?
    private let queue = DispatchQueue(label: "com.duetbar.writer")
    private let uidLock = NSLock()
    private var uid: String?

    /// The uid of the device in Glue's tree, which every property ID is hashed
    /// from. Kept fresh by each read, since a reconnected Duet can come back
    /// with a different one.
    var deviceUID: String? {
        get { uidLock.lock(); defer { uidLock.unlock() }; return uid }
        set { uidLock.lock(); uid = newValue; uidLock.unlock() }
    }

    func write(_ id: PropertyID, value: [UInt8]) {
        // Without a uid there is no valid ID, and Glue ignores unknown ones.
        guard let uid = deviceUID else { return }
        let payload = frame(setPropertyMessage(id, idBytes: id.bytes(uid: uid), value: value))
        queue.async { [self] in
            if send(payload) { return }
            connection = nil
            _ = send(payload)
        }
    }

    private func send(_ payload: Data) -> Bool {
        if connection == nil {
            guard let port = GlueService.discoverPort(),
                  let fresh = try? GlueConnection(port: port) else { return false }
            fresh.greet()
            Thread.sleep(forTimeInterval: 0.25)
            connection = fresh
        }
        return connection?.send(payload) ?? false
    }
}
