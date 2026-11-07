import Darwin
import Foundation
import IOKit

/// One line of ultrasonic telemetry: `D,<centimetres or -1>,<C|W|G|N>`.
struct PostureSerialTelemetry: Equatable {
    let distanceCM: Double?
    let zone: PostureDistanceZone

    static func parse(_ line: String) -> PostureSerialTelemetry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "D" else { return nil }
        guard let zone = PostureDistanceZone(rawValue: String(parts[2])) else { return nil }
        guard let value = Double(parts[1]), value.isFinite else { return nil }
        if value == -1, zone == .none {
            return PostureSerialTelemetry(distanceCM: nil, zone: zone)
        }
        guard value > 0, value <= 600 else { return nil }
        return PostureSerialTelemetry(distanceCM: value, zone: zone)
    }
}

/// Independent climate frame: E,<Celsius>,<relative humidity %>, or E,ERR.
struct PostureEnvironmentTelemetry: Equatable {
    let temperatureC: Double?
    let humidityPercent: Double?

    static func parse(_ line: String) -> Self? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 64 else { return nil }
        if trimmed == "E,ERR" { return Self(temperatureC: nil, humidityPercent: nil) }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "E",
              let temperature = Double(parts[1]), temperature.isFinite,
              let humidity = Double(parts[2]), humidity.isFinite,
              (-40...80).contains(temperature), (0...100).contains(humidity) else { return nil }
        return Self(temperatureC: temperature, humidityPercent: humidity)
    }
}

protocol PostureArduinoInput: AnyObject {
    var onState: ((PostureArduinoLink.State) -> Void)? { get set }
    var onTelemetry: ((PostureSerialTelemetry) -> Void)? { get set }
    var onEnvironment: ((PostureEnvironmentTelemetry) -> Void)? { get set }
    var onBoardRemembered: ((PostureSerialBoard) -> Void)? { get set }
    func start(enabled: Bool)
    func stop()
    func notify(_ signal: PostureArduinoSignal)
}

/// A USB serial board the firmware can run on.
struct PostureSerialBoard: Equatable, Codable {
    let path: String
    let serialNumber: String?
    let vendorID: Int
    let productID: Int
}

enum PostureSerialDiscovery {
    static let supportedVendorIDs: Set<Int> = [0x2341, 0x2A03, 0x1A86, 0x0403, 0x10C4]
    static let unoProductIDs: Set<Int> = [0x0001, 0x0043, 0x0243, 0x0010]

    static func boards() -> [PostureSerialBoard] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOSerialBSDClient"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [PostureSerialBoard] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, "IOCalloutDevice") as? String,
                  path.hasPrefix("/dev/cu.") else { continue }
            guard let vendor = usbIdentifier(service, "idVendor"),
                  supportedVendorIDs.contains(vendor) else { continue }
            let product = usbIdentifier(service, "idProduct") ?? 0
            found.append(
                PostureSerialBoard(
                    path: path,
                    serialNumber: usbString(service, "USB Serial Number"),
                    vendorID: vendor,
                    productID: product
                )
            )
        }
        return found
    }

    /// Prefers the remembered board, then a single native Uno, then a lone candidate.
    static func select(from boards: [PostureSerialBoard], remembered: PostureSerialBoard?) -> PostureSerialBoard? {
        if let remembered, let match = boards.first(where: {
            $0.serialNumber != nil
                && $0.serialNumber == remembered.serialNumber
                && $0.vendorID == remembered.vendorID
                && $0.productID == remembered.productID
        }) {
            return match
        }
        let unos = boards.filter {
            [0x2341, 0x2A03].contains($0.vendorID) && unoProductIDs.contains($0.productID)
        }
        if unos.count == 1 { return unos[0] }
        return boards.count == 1 ? boards[0] : nil
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func usbString(_ service: io_object_t, _ key: String) -> String? {
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<6 {
            if let value = property(entry, key) as? String { return value }
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }

    private static func usbIdentifier(_ service: io_object_t, _ key: String) -> Int? {
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<6 {
            if let number = property(entry, key) as? NSNumber { return number.intValue }
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }
}

/// Byte sent to the Uno at 115200 baud so it can drive the status LED.
enum PostureArduinoSignal: String {
    case good = "G"
    /// Bad posture that already lasted past the alert delay.
    case alert = "B"
    /// Bad posture still inside the delay, or no confident posture yet.
    case pending = "U"
}

/// Thin non-blocking serial port on top of POSIX termios.
final class PostureSerialPort {
    private(set) var isOpen = false
    var onData: ((Data) -> Void)?
    var onFailure: (() -> Void)?

    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { close() }

    func open(path: String) -> Bool {
        close()
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CRTSCTS)
        settings.c_cflag = (settings.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        settings.c_iflag = 0
        settings.c_oflag = 0
        settings.c_lflag = 0
        withUnsafeMutablePointer(to: &settings.c_cc) { control in
            control.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { bytes in
                bytes[Int(VMIN)] = 0
                bytes[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        cfsetspeed(&settings, speed_t(B115200))
        _ = tcsetattr(descriptor, TCSANOW, &settings)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        self.descriptor = descriptor
        isOpen = true
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    func write(_ text: String) {
        guard isOpen else { return }
        var bytes = Array(text.utf8)
        let written = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(descriptor, base, buffer.count)
        }
        if written < 0, errno != EAGAIN, errno != EWOULDBLOCK {
            fail()
        }
        bytes.removeAll(keepingCapacity: false)
    }

    func close() {
        source?.cancel()
        source = nil
        if isOpen {
            isOpen = false
            descriptor = -1
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(descriptor, base, raw.count)
        }
        if count > 0 {
            onData?(Data(buffer[0..<count]))
        } else if count == 0 {
            fail()
        } else if errno != EAGAIN, errno != EWOULDBLOCK {
            fail()
        }
    }

    private func fail() {
        close()
        onFailure?()
    }
}

/// Keeps the ultrasonic firmware link alive: discovers the board, reconnects after
/// unplugging and sends the posture byte the sketch turns into the LED state.
final class PostureArduinoLink: PostureArduinoInput {
    enum State: Equatable {
        case disabled
        case searching
        case connecting
        case connected
        case failed(String)
    }

    var onState: ((State) -> Void)?
    var onTelemetry: ((PostureSerialTelemetry) -> Void)?
    var onEnvironment: ((PostureEnvironmentTelemetry) -> Void)?
    var onBoardRemembered: ((PostureSerialBoard) -> Void)?

    static let enabledPreferenceKey = "notch.posture.arduinoEnabled"
    static let boardPreferenceKey = "notch.posture.arduinoBoard"

    /// Serial work queue. The label identifies this queue in crash reports and
    /// Instruments, so it uses the product name rather than the legacy
    /// notchtriage prefix kept on the bundle identifier.
    private let queue = DispatchQueue(label: "com.sitwell.posture.serial")
    private lazy var port = PostureSerialPort(queue: queue)
    private var connectTimer: DispatchSourceTimer?
    private var sendTimer: DispatchSourceTimer?
    private var receiveBuffer = Data()
    private var signal: PostureArduinoSignal = .pending
    private var isEnabled = false
    private var readyAt: Date = .distantPast
    private var state: State = .disabled
    private var lastTelemetry: PostureSerialTelemetry?

    func start(enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = enabled
            guard enabled else {
                self.shutdown(state: .disabled)
                return
            }
            guard self.connectTimer == nil else { return }
            self.publish(.searching)
            self.scheduleTimers()
            self.connectIfNeeded()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = false
            self.shutdown(state: .disabled)
        }
    }

    func notify(_ signal: PostureArduinoSignal) {
        queue.async { [weak self] in self?.signal = signal }
    }

    private func scheduleTimers() {
        let connect = DispatchSource.makeTimerSource(queue: queue)
        connect.schedule(deadline: .now() + 3, repeating: 3)
        connect.setEventHandler { [weak self] in self?.connectIfNeeded() }
        connect.resume()
        connectTimer = connect

        let send = DispatchSource.makeTimerSource(queue: queue)
        send.schedule(deadline: .now() + 0.25, repeating: 0.25)
        send.setEventHandler { [weak self] in self?.sendHeartbeat() }
        send.resume()
        sendTimer = send
    }

    private func connectIfNeeded() {
        guard isEnabled, !port.isOpen, Date() >= readyAt else { return }
        let remembered = Self.rememberedBoard()
        let boards = PostureSerialDiscovery.boards()
        guard let board = PostureSerialDiscovery.select(from: boards, remembered: remembered) else {
            if !boards.isEmpty {
                publish(.failed("Several USB serial ports found. Keep only one Arduino connected."))
            } else {
                publish(.searching)
            }
            readyAt = Date().addingTimeInterval(3)
            return
        }
        publish(.connecting)
        port.onData = { [weak self] data in self?.consume(data) }
        port.onFailure = { [weak self] in
            guard let self else { return }
            self.receiveBuffer.removeAll(keepingCapacity: false)
            self.lastTelemetry = nil
            self.readyAt = Date().addingTimeInterval(3)
            self.publish(.searching)
        }
        guard port.open(path: board.path) else {
            readyAt = Date().addingTimeInterval(3)
            publish(.failed("The USB serial port is busy. Close the Arduino Serial Monitor and retry."))
            return
        }
        // Opening USB serial resets an Uno; let its bootloader finish.
        readyAt = Date().addingTimeInterval(2)
        receiveBuffer.removeAll(keepingCapacity: false)
        publish(.connected)
        onBoardRemembered?(board)
    }

    private func sendHeartbeat() {
        guard isEnabled, port.isOpen, Date() >= readyAt else { return }
        port.write(signal.rawValue)
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        while let end = receiveBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: receiveBuffer[receiveBuffer.startIndex..<end], as: UTF8.self)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...end)
            if let environment = PostureEnvironmentTelemetry.parse(line) {
                DispatchQueue.main.async { [weak self] in self?.onEnvironment?(environment) }
                continue
            }
            guard let telemetry = PostureSerialTelemetry.parse(line) else { continue }
            lastTelemetry = telemetry
            DispatchQueue.main.async { [weak self] in self?.onTelemetry?(telemetry) }
        }
        if receiveBuffer.count > 6_000 {
            receiveBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func shutdown(state newState: State) {
        connectTimer?.cancel()
        connectTimer = nil
        sendTimer?.cancel()
        sendTimer = nil
        if port.isOpen {
            port.write(PostureArduinoSignal.pending.rawValue)
            port.close()
        }
        receiveBuffer.removeAll(keepingCapacity: false)
        lastTelemetry = nil
        readyAt = .distantPast
        publish(newState)
    }

    private func publish(_ newState: State) {
        let deliver = { [weak self] in
            guard let self, self.state != newState else { return }
            self.state = newState
            self.onState?(newState)
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    private static func rememberedBoard() -> PostureSerialBoard? {
        guard let data = UserDefaults.standard.data(forKey: boardPreferenceKey) else { return nil }
        return try? JSONDecoder().decode(PostureSerialBoard.self, from: data)
    }

    static func remember(_ board: PostureSerialBoard) {
        guard let data = try? JSONEncoder().encode(board) else { return }
        UserDefaults.standard.set(data, forKey: boardPreferenceKey)
    }
}
