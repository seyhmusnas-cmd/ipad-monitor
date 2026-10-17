// MonitorHost: captures a Mac display and streams it over USB to the Monitor app on an old iPad.
// Lives in the menu bar; logs go to ~/Library/Logs/MonitorHost.log.
//
// Pipeline:  virtual display (CGVirtualDisplay) -> ScreenCaptureKit -> H.264 (VideoToolbox) -> usbmuxd -> iPad :2345
//
// Protocol (Mac -> iPad):  [4-byte length, big-endian][1-byte type][payload]
//   type 1 = JPEG frame
//   type 2 = H.264 frame: [flags: 1 = key frame][key frames only: 2-byte SPS length, SPS,
//            2-byte PPS length, PPS][NAL units in AVCC format]
// Protocol (iPad -> Mac):  [1-byte type][payload]
//   0x01 ack, 0x02 ack + "please send a key frame"
//   0x10 tap [x][y] · 0x11 right click [x][y] · 0x12 drag [phase][x][y] · 0x13 scroll [x][y][dx][dy]
//   x/y: 0..65535 within the picture (u16); dx/dy: 1/32768ths of the picture size (i16); all big-endian.
// A new frame is only encoded once the previous one is acked; frames captured in between are
// dropped *before* encoding, so latency never builds up and the H.264 chain stays intact.
//
// Environment variables:
//   MONITOR_UDID=<udid>    only use this device (default: first USB device running the app)
//   MONITOR_CODEC=jpeg     use JPEG instead of H.264
//   MONITOR_BITRATE=6      H.264 average bit rate (Mbit/s)
//   MONITOR_QUALITY=0.6    JPEG quality
//   MONITOR_MIRROR=1       don't create a virtual display; mirror the main display
//   MONITOR_BENCH=1        benchmark: keep sending frames even when the screen is idle

import AppKit
import ApplicationServices
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import ServiceManagement
import VideoToolbox

let environment = ProcessInfo.processInfo.environment
let deviceUDID = environment["MONITOR_UDID"]
let devicePort: UInt16 = 2345
let maxPixels = CGSize(width: 1024, height: 768)  // iPad mini / iPad 2 screen
let useJPEG = environment["MONITOR_CODEC"] == "jpeg"
let jpegQuality = Double(environment["MONITOR_QUALITY"] ?? "") ?? 0.6
let h264BitRate = Int((Double(environment["MONITOR_BITRATE"] ?? "") ?? 6) * 1_000_000)
// Benchmark: frames are sent continuously even if the screen doesn't change, to find the
// ceiling of the pipeline. With H.264 every frame is a key frame (worst case).
let benchmark = environment["MONITOR_BENCH"] == "1"
let mirrorMainDisplay = environment["MONITOR_MIRROR"] == "1"
// Once the screen has been idle this long, the last frame is resent as a high-quality key frame.
let idleRefreshDelay: TimeInterval = 0.3

let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MonitorHost.log")
private let logFile: FileHandle? = {
    // Start fresh on every launch so the file doesn't grow forever.
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    return try? FileHandle(forWritingTo: logURL)
}()
private let logLock = NSLock()

func log(_ message: String) {
    let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
    logLock.lock()
    defer { logLock.unlock() }
    FileHandle.standardOutput.write(Data(line.utf8))
    logFile?.write(Data(line.utf8))
}

// MARK: - Status

/// Forwards the sender's state to the menu bar. Safe to call from any thread.
final class StatusBoard: @unchecked Sendable {
    var onChange: ((String, Bool) -> Void)?

    func set(_ text: String, connected: Bool) {
        DispatchQueue.main.async { self.onChange?(text, connected) }
    }
}

let status = StatusBoard()

// MARK: - usbmuxd

/// Talks to macOS's usbmuxd to open a tunnel over USB to a TCP port on the iPad.
enum USBMux {
    struct Failure: Error, CustomStringConvertible { let description: String }

    struct Device {
        let id: Int
        let udid: String
    }

    private static let common: [String: Any] = [
        "ClientVersionString": "MonitorHost",
        "ProgName": "MonitorHost",
        "kLibUSBMuxVersion": 3,
    ]

    /// iOS devices currently connected over USB (Wi-Fi sync devices are skipped).
    static func usbDevices() throws -> [Device] {
        let fd = try openSocket()
        defer { close(fd) }
        try send(fd, ["MessageType": "ListDevices"])
        let reply = try receive(fd)
        return (reply["DeviceList"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any],
                  props["ConnectionType"] as? String == "USB",
                  let id = props["DeviceID"] as? Int,
                  let udid = props["SerialNumber"] as? String else { return nil }
            return Device(id: id, udid: udid)
        }
    }

    /// On success the returned socket is connected straight to the port on the iPad.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        do {
            try send(fd, ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(port.bigEndian)])
            let reply = try receive(fd)
            let result = reply["Number"] as? Int ?? -1
            guard result == 0 else { throw Failure(description: "usbmuxd Connect result \(result)") }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            throw Failure(description: "couldn't connect to usbmuxd")
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func send(_ fd: Int32, _ message: [String: Any]) throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: common.merging(message) { $1 }, format: .xml, options: 0)
        // Header: length, version (1 = plist), message type (8 = plist), tag; all little-endian.
        var header = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        try writeAll(fd, header + body)
    }

    private static func receive(_ fd: Int32) throws -> [String: Any] {
        let header = try readAll(fd, count: 16)
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let body = try readAll(fd, count: Int(length) - 16)
        return try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] ?? [:]
    }
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            guard n > 0 else { throw USBMux.Failure(description: "write failed") }
            offset += n
        }
    }
}

func readAll(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < count {
            let n = read(fd, raw.baseAddress! + offset, count - offset)
            guard n > 0 else { throw USBMux.Failure(description: "read failed") }
            offset += n
        }
    }
    return data
}

// MARK: - Latest frame

/// The capturer drops the newest screen image here; the sender takes the newest one and skips the rest.
/// Encoding happens on the sender side, so skipped frames never break the H.264 chain.
final class LatestFrame: @unchecked Sendable {
    private let condition = NSCondition()
    private var pixels: CVPixelBuffer?
    private var sequence = 0

    func put(_ buffer: CVPixelBuffer) {
        condition.lock()
        pixels = buffer
        sequence += 1
        condition.signal()
        condition.unlock()
    }

    /// Waits for a frame newer than `seen`; returns nil if `timeout` expires first.
    func next(after seen: Int, timeout: TimeInterval? = nil) -> (CVPixelBuffer, Int)? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while pixels == nil || sequence == seen {
            if let deadline {
                if !condition.wait(until: deadline) { return nil }
            } else {
                condition.wait()
            }
        }
        return (pixels!, sequence)
    }
}

let latest = LatestFrame()

// MARK: - Encoders

enum MessageType: UInt8 {
    case jpeg = 1
    case h264 = 2
}

protocol FrameEncoder {
    var name: String { get }
    func encode(_ pixels: CVPixelBuffer, keyFrame: Bool) -> Data?
    var messageType: MessageType { get }
}

final class JPEGEncoder: FrameEncoder {
    let name = "JPEG"
    let messageType = MessageType.jpeg
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func encode(_ pixels: CVPixelBuffer, keyFrame: Bool) -> Data? {
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality]
        return context.jpegRepresentation(of: CIImage(cvPixelBuffer: pixels), colorSpace: colorSpace, options: options)
    }
}

/// The Mac's hardware H.264 encoder. The iPad mini's A5 can decode High profile up to level 4.1
/// in hardware; frame reordering (B-frames) is off because it adds latency.
final class H264Encoder: FrameEncoder {
    let name: String
    let messageType = MessageType.h264
    private let session: VTCompressionSession

    init(width: Int, height: Int) throws {
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else {
            throw USBMux.Failure(description: "couldn't create the H.264 encoder (\(status))")
        }
        session = created
        name = String(format: "H.264 %dx%d %.0f Mbit/s", width, height, Double(h264BitRate) / 1e6)

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_AverageBitRate: h264BitRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 30,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func encode(_ pixels: CVPixelBuffer, keyFrame: Bool) -> Data? {
        var packed: Data?
        // Timestamps are wall-clock time: rate control then gives more bits to a frame that follows
        // a long pause, so the "screen went idle" refresh comes out in high quality.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample else { return }
            packed = H264Encoder.pack(sample)
        }
        guard status == noErr else { return nil }
        // Force the frame out right away, which makes encoding synchronous.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return packed
    }

    private static func pack(_ sample: CMSampleBuffer) -> Data? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var out = Data([isKey ? 1 : 0])

        if isKey {
            guard let format = sample.formatDescription else { return nil }
            for index in 0..<2 {  // 0 = SPS, 1 = PPS
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer else { return nil }
                var length = UInt16(size).bigEndian
                out.append(Data(bytes: &length, count: 2))
                out.append(pointer, count: size)
            }
        }

        guard let block = sample.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var nalUnits = Data(count: length)
        let copied = nalUnits.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copied == noErr else { return nil }
        out.append(nalUnits)
        return out
    }
}

// MARK: - Touch -> mouse

/// Turns touch messages from the iPad into real mouse events on the virtual display.
/// Without the Accessibility permission macOS silently drops these events.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastClickTime = Date.distantPast
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 0
    private var warnedAboutPermission = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    static let payloadLengths: [UInt8: Int] = [0x10: 4, 0x11: 4, 0x12: 5, 0x13: 8]

    func handle(_ type: UInt8, _ b: [UInt8]) {
        guard AXIsProcessTrusted() else {
            if !warnedAboutPermission {
                log("Ignoring touches: give MonitorHost the Accessibility permission (System Settings > Privacy & Security > Accessibility)")
                warnedAboutPermission = true
            }
            return
        }
        switch type {
        case 0x10:
            click(at: point(b, 0))
        case 0x11:
            let p = point(b, 0)
            post(.mouseMoved, at: p)
            post(.rightMouseDown, at: p, button: .right)
            post(.rightMouseUp, at: p, button: .right)
        case 0x12:
            let p = point(b, 1)
            switch b[0] {
            case 0:
                post(.mouseMoved, at: p)
                post(.leftMouseDown, at: p)
            case 1:
                post(.leftMouseDragged, at: p)
            default:
                post(.leftMouseUp, at: p)
            }
        case 0x13:
            scroll(at: point(b, 0), dx: i16(b, 4), dy: i16(b, 6))
        default:
            break
        }
    }

    private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    private func i16(_ b: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(b, i)))) }

    /// Maps a 0..65535 coordinate to the virtual display's actual position on the desktop.
    /// CGDisplayBounds is always current, so this stays right when the resolution changes.
    private func point(_ b: [UInt8], _ i: Int) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + Double(u16(b, i)) / 65535 * (bounds.width - 1),
                       y: bounds.minY + Double(u16(b, i + 2)) / 65535 * (bounds.height - 1))
    }

    private func click(at p: CGPoint) {
        // A quick tap close to the previous one counts as a double (triple, ...) click.
        let now = Date()
        let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 15
        clickCount = now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval && near ? clickCount + 1 : 1
        lastClickTime = now
        lastClickPoint = p
        post(.mouseMoved, at: p)
        post(.leftMouseDown, at: p, clickState: clickCount)
        post(.leftMouseUp, at: p, clickState: clickCount)
    }

    private func scroll(at p: CGPoint, dx: Int, dy: Int) {
        let bounds = CGDisplayBounds(displayID)
        post(.mouseMoved, at: p)  // scroll events go to the window under the cursor
        // Content follows the fingers, like on a touch screen.
        let pixelsX = Int32((Double(dx) / 32768 * bounds.width).rounded())
        let pixelsY = Int32((Double(dy) / 32768 * bounds.height).rounded())
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: pixelsY, wheel2: pixelsX, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clickState: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }
}

/// The incoming side of an iPad connection: hands acks to the sender and touches to the injector.
/// Acks and touches arrive interleaved on the same socket, so reading happens on its own thread.
final class Link: @unchecked Sendable {
    let fd: Int32
    private let injector: InputInjector
    private let acks = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var keyRequested = false
    private var closed = false

    init(fd: Int32, injector: InputInjector) {
        self.fd = fd
        self.injector = injector
        Thread { [self] in readLoop() }.start()
    }

    /// Waits for the next ack; returns true if the iPad asked for a key frame.
    func waitForAck() throws -> Bool {
        // If the iPad app goes to the background no ack ever arrives; time out instead of hanging.
        guard acks.wait(timeout: .now() + 5) == .success else {
            throw USBMux.Failure(description: "ack timed out")
        }
        lock.lock()
        defer { lock.unlock() }
        if closed { throw USBMux.Failure(description: "the iPad closed the connection") }
        let wantsKey = keyRequested
        keyRequested = false
        return wantsKey
    }

    /// Wakes up and ends the reader thread; the sender closes the socket.
    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func readLoop() {
        defer {
            lock.lock()
            closed = true
            lock.unlock()
            acks.signal()
        }
        while let type = try? readAll(fd, count: 1)[0] {
            switch type {
            case 0x01, 0x02:
                if type == 0x02 {
                    lock.lock()
                    keyRequested = true
                    lock.unlock()
                }
                acks.signal()
            default:
                guard let length = InputInjector.payloadLengths[type],
                      let body = try? readAll(fd, count: length) else {
                    log("Unknown message from the iPad (\(type)), closing the connection")
                    return
                }
                let bytes = [UInt8](body)
                DispatchQueue.main.async { [injector] in injector.handle(type, bytes) }
            }
        }
    }
}

// MARK: - Sender

/// Finds a USB device with the Monitor app listening and connects to it.
func connectToIPad() -> (fd: Int32, udid: String)? {
    let devices = ((try? USBMux.usbDevices()) ?? []).filter {
        deviceUDID == nil || $0.udid.lowercased() == deviceUDID!.lowercased()
    }
    for device in devices {
        if let fd = try? USBMux.connect(deviceID: device.id, port: devicePort) {
            return (fd, device.udid)
        }
    }
    return nil
}

func senderLoop(displayID: CGDirectDisplayID) {
    let injector = InputInjector(displayID: displayID)
    var lastProblem = ""
    func problem(_ message: String) {
        if message != lastProblem {
            log(message + ", waiting…")
            status.set(message, connected: false)
        }
        lastProblem = message
    }

    while true {
        guard let (fd, udid) = connectToIPad() else {
            let anyDevice = !((try? USBMux.usbDevices()) ?? []).isEmpty
            problem(anyDevice ? "Monitor app isn't open on the iPad" : "No iPad on USB")
            sleep(1)
            continue
        }
        lastProblem = ""
        log("Connected to iPad \(udid.prefix(8))…")
        status.set("iPad connected", connected: true)

        let link = Link(fd: fd, injector: injector)

        // A fresh encoder per connection: the stream starts with a key frame and the iPad gets a clean decoder.
        var encoder: FrameEncoder?
        var sent = -1
        var needKey = true
        var refreshed = true
        var lastPixels: CVPixelBuffer?
        var frames = 0, keyFrames = 0, bytes = 0
        var roundTrips: [Double] = []
        var since = Date()
        do {
            while true {
                var pixels: CVPixelBuffer
                var key = needKey || benchmark
                if benchmark {
                    pixels = latest.next(after: -1)!.0
                } else if let (fresh, seq) = latest.next(after: sent, timeout: refreshed ? nil : idleRefreshDelay) {
                    pixels = fresh
                    sent = seq
                    refreshed = useJPEG  // JPEG frames don't need a refresh
                } else if let last = lastPixels {
                    // The screen went idle: resend the last image once as a high-quality key frame
                    // so text that got blurry while moving becomes sharp again.
                    pixels = last
                    key = true
                    refreshed = true
                } else {
                    refreshed = true
                    continue
                }
                lastPixels = pixels

                if encoder == nil {
                    encoder = useJPEG ? JPEGEncoder()
                        : try H264Encoder(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                    log("Encoder: \(encoder!.name)")
                }
                guard let payload = encoder!.encode(pixels, keyFrame: key) else { continue }
                needKey = false

                var length = UInt32(payload.count + 1).bigEndian
                let start = DispatchTime.now().uptimeNanoseconds
                try writeAll(fd, Data(bytes: &length, count: 4) + [encoder!.messageType.rawValue] + payload)
                let wantsKey = try link.waitForAck()
                // Round trip: USB transfer + handing the frame to the iPad's decoder + ack.
                roundTrips.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                if wantsKey {
                    log("iPad asked for a key frame")
                    needKey = true
                }

                frames += 1
                bytes += payload.count
                if key { keyFrames += 1 }
                let elapsed = Date().timeIntervalSince(since)
                if elapsed >= 5 {
                    roundTrips.sort()
                    let mid = roundTrips[roundTrips.count / 2]
                    let p95 = roundTrips[min(roundTrips.count - 1, roundTrips.count * 95 / 100)]
                    status.set(String(format: "iPad connected · %.0f fps", Double(frames) / elapsed), connected: true)
                    log(String(format: "%.1f fps (%d key) · %.1f KB/frame · %.2f MB/s · round trip median %.0f ms, p95 %.0f ms",
                               Double(frames) / elapsed, keyFrames, Double(bytes) / Double(frames) / 1024,
                               Double(bytes) / elapsed / 1_048_576, mid, p95))
                    frames = 0
                    keyFrames = 0
                    bytes = 0
                    roundTrips.removeAll()
                    since = Date()
                }
            }
        } catch {
            log("Connection lost (\(error)), retrying…")
            status.set("Connection lost, retrying", connected: false)
        }
        link.shutdown()
        close(fd)
    }
}

// MARK: - Virtual display

/// A virtual display that macOS treats like a second monitor the size of the iPad.
/// It exists as long as this object does; quitting MonitorHost removes it.
final class VirtualScreen {
    let display: CGVirtualDisplay

    // 4:3 modes; the first one matches the iPad 1:1. The others give more room but are scaled
    // down on the iPad. Pick one from the menu or System Settings > Displays.
    static let modes: [(Int, Int)] = [(1024, 768), (1280, 960), (1600, 1200)]

    init() throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "iPad mini"
        descriptor.maxPixelsWide = 1600
        descriptor.maxPixelsHigh = 1200
        descriptor.sizeInMillimeters = CGSize(width: 160, height: 120)  // 7.9" 4:3
        // Fixed IDs: macOS remembers the display arrangement (left/right of the main display) by these.
        descriptor.vendorID = 0x5345
        descriptor.productID = 0x4D31
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, _ in log("The system removed the virtual display") }

        display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = VirtualScreen.modes.map {
            CGVirtualDisplayMode(width: UInt($0.0), height: UInt($0.1), refreshRate: 60)
        }
        guard display.displayID != 0, display.apply(settings) else {
            throw USBMux.Failure(description: "couldn't create the virtual display")
        }
        log("Created virtual display \"iPad mini\" (display \(display.displayID)), 1024x768")
    }
}

// MARK: - Screen capture

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "capture")
    private var stream: SCStream?

    func start(displayID: CGDirectDisplayID) async throws {
        // A freshly created virtual display can take a moment to show up in ScreenCaptureKit.
        var found: SCDisplay?
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            found = content.displays.first { $0.displayID == displayID }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let display = found else {
            throw USBMux.Failure(description: "display \(displayID) isn't available for capture")
        }

        // Fit into the iPad's 1024x768 while keeping the aspect ratio.
        let scale = min(maxPixels.width / CGFloat(display.width), maxPixels.height / CGFloat(display.height))
        let config = SCStreamConfiguration()
        // The H.264 encoder is most efficient with YUV 4:2:0, and Core Image reads it fine for JPEG.
        // 4:2:0 needs even dimensions.
        config.width = Int((CGFloat(display.width) * scale / 2).rounded()) * 2
        config.height = Int((CGFloat(display.height) * scale / 2).rounded()) * 2
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 4

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log("Capturing display \(display.displayID), \(display.width)x\(display.height) pt -> \(config.width)x\(config.height) px")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only take "complete" frames whose content changed; ScreenCaptureKit sends idle frames otherwise.
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = info.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        latest.put(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Screen capture stopped: \(error)")
        status.set("Screen capture stopped", connected: false)
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var virtualScreen: VirtualScreen?
    private let capturer = Capturer()
    private var displayID: CGDirectDisplayID = 0
    private var connected = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two running copies would mean two virtual displays; quit the second one.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            log("MonitorHost is already running; quitting this copy")
            NSApp.terminate(nil)
            return
        }
        log("MonitorHost starting (\(Bundle.main.bundlePath), \(useJPEG ? "JPEG" : "H.264")\(benchmark ? ", BENCHMARK" : ""))")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "MonitorHost")
        statusItem.button?.appearsDisabled = true
        menu.delegate = self
        statusItem.menu = menu
        status.onChange = { [weak self] text, connected in self?.update(text, connected: connected) }

        enableLoginItemOnFirstRun()

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            log("No Screen Recording permission; allow it in System Settings and relaunch MonitorHost")
            update("Screen Recording permission needed", connected: false)
            return
        }
        // Accessibility permission is needed for touch; macOS shows its prompt if it's missing.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

        if !mirrorMainDisplay {
            do {
                virtualScreen = try VirtualScreen()
            } catch {
                log("\(error); mirroring the main display instead")
            }
        }
        displayID = virtualScreen?.display.displayID ?? CGMainDisplayID()

        let target = displayID
        Thread { senderLoop(displayID: target) }.start()
        Task { @MainActor in
            do {
                try await capturer.start(displayID: target)
            } catch {
                log("Couldn't start screen capture: \(error)")
                update("Can't capture the screen", connected: false)
            }
        }
    }

    private func update(_ text: String, connected: Bool) {
        statusLine.title = text
        self.connected = connected
        statusItem?.button?.appearsDisabled = !connected
        statusItem?.button?.toolTip = "MonitorHost — \(text)"
    }

    // The menu is rebuilt every time it opens, so permissions and resolution are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("Allow Screen Recording…", #selector(openScreenRecordingSettings)))
            menu.addItem(item("Relaunch MonitorHost", #selector(relaunch)))
        }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Allow Accessibility (for touch)…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        if virtualScreen != nil {
            let resolution = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = CGDisplayCopyDisplayMode(displayID)
            for (w, h) in VirtualScreen.modes {
                let title = w == 1024 ? "\(w) × \(h)  (1:1 on the iPad)" : "\(w) × \(h)  (more space)"
                let mode = item(title, #selector(setResolution(_:)))
                mode.representedObject = [w, h]
                mode.state = current?.width == w && current?.height == h ? .on : .off
                sub.addItem(mode)
            }
            resolution.submenu = sub
            menu.addItem(resolution)
            menu.addItem(item("Display Settings…", #selector(openDisplaySettings)))
        }

        let login = item("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit MonitorHost", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func setResolution(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? [Int],
              let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.width == size[0] && $0.height == size[1] }) else { return }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
        log("Virtual display resolution: \(size[0])x\(size[1])")
    }

    /// On first launch from a permanent location (an Applications folder), register as a login item.
    private func enableLoginItemOnFirstRun() {
        let defaults = UserDefaults.standard
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !defaults.bool(forKey: "loginItemConfigured"),
              path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else { return }
        defaults.set(true, forKey: "loginItemConfigured")
        do {
            try SMAppService.mainApp.register()
            log("Registered as a login item: MonitorHost will start when you log in")
        } catch {
            log("Couldn't register as a login item: \(error)")
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("Removed login item")
            } else {
                try SMAppService.mainApp.register()
                log("Added login item")
            }
        } catch {
            log("Couldn't change the login item: \(error)")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func openScreenRecordingSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openDisplaySettings() {
        openSettings("x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }

    private func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundleURL
        // This copy quits first so the new one doesn't trip the single-instance check.
        Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", "sleep 1; open \"\(path.path)\""])
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Startup

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon, menu bar only
app.run()
