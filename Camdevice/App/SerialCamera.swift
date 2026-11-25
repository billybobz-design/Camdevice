import Darwin
import Foundation

struct SerialCamera: Identifiable, Sendable {
    let port: String
    let supportsFlashCleanup: Bool
    var id: String { port }

    private static let portLock = NSLock()
    private static let photoHeader = #/FILE (IMG_[0-9]{4}\.JPG) ([1-9][0-9]{0,7})/#
    private static let cleanupResult = #/CAMDEVICE FLASH CLEARED ([0-9]{1,5}) ([0-9]{1,5})/#

    init(port: String, supportsFlashCleanup: Bool = false) {
        self.port = port
        self.supportsFlashCleanup = supportsFlashCleanup
    }

    static func ports() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    func identify() throws -> SerialCamera {
        try withConnection { connection in
            let supported = try supportsFlashCleanup(using: connection)
            return SerialCamera(port: port, supportsFlashCleanup: supported)
        }
    }

    func clearFlashPhotos() throws -> (removed: Int, failed: Int) {
        try withConnection { connection in
            guard try supportsFlashCleanup(using: connection) else { throw SerialCameraError.updateRequired }

            var line: String
            do {
                try connection.send("cl")
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                repeat {
                    line = try connection.line(until: deadline)
                } while !line.hasPrefix("CAMDEVICE FLASH CLEARED ") && !line.hasPrefix("ERROR ")
            } catch {
                throw SerialCameraError.cleanupUnconfirmed
            }
            if line.hasPrefix("ERROR ") { throw SerialCameraError.device(line) }
            guard let match = line.wholeMatch(of: Self.cleanupResult),
                  let removed = Int(match.1), let failed = Int(match.2),
                  removed + failed <= 10_000 else {
                throw SerialCameraError.cleanupUnconfirmed
            }
            return (removed, failed)
        }
    }

    private func supportsFlashCleanup(using connection: SerialConnection) throws -> Bool {
        try connection.send("fc")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let line: String
            do {
                line = try connection.line(until: deadline)
            } catch SerialCameraError.timeout {
                return false
            }
            if line == "CAMDEVICE FLASH CLEAR 1" { return true }
            if line.hasPrefix("ERROR ") { return false }
        }
    }

    func takePhoto() throws {
        try withConnection { connection in
            try connection.send("pz")
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            var messages: [String] = []
            while true {
                let line = try connection.line(until: deadline)
                if line == "OK Camera stopped." { return }
                messages.append(line)
                if messages.count > 8 { messages.removeFirst() }
                if line.hasPrefix("ERROR ") {
                    throw SerialCameraError.device(messages.joined(separator: "\n"))
                }
            }
        }
    }

    func downloadPhotos(to folder: URL) throws -> [URL] {
        try withConnection { connection in
            try connection.send("dc")
            let header = try connection.line()
            guard header == "CAMDEVICE EXPORT 1" else {
                if header.hasPrefix("ERROR ") { throw SerialCameraError.device(header) }
                throw SerialCameraError.invalidResponse
            }

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var photos: [URL] = []
            var names: Set<String> = []
            while true {
                let line = try connection.line()
                if line == "END" { return photos }
                guard let match = line.wholeMatch(of: Self.photoHeader),
                      let count = Int(match.2), names.insert(String(match.1)).inserted else {
                    throw SerialCameraError.invalidResponse
                }

                let file = folder.appending(path: String(match.1), directoryHint: .notDirectory)
                try Data().write(to: file, options: .withoutOverwriting)
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                try connection.copy(count, to: output)
                photos.append(file)
            }
        }
    }

    private func withConnection<Result>(_ operation: (SerialConnection) throws -> Result) throws -> Result {
        guard Self.portLock.try() else { throw SerialCameraError.system(EBUSY) }
        defer { Self.portLock.unlock() }
        let connection = try SerialConnection(port: port)
        try connection.send("id")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while try connection.line(until: deadline) != "CAMDEVICE READY 1" {}
        return try operation(connection)
    }
}

private enum SerialCameraError: LocalizedError {
    case system(Int32)
    case disconnected
    case timeout
    case invalidResponse
    case updateRequired
    case cleanupUnconfirmed
    case device(String)

    var errorDescription: String? {
        switch self {
        case .system(EBUSY), .system(EWOULDBLOCK): "串口正被占用。请关闭拍照终端或串口监视器，再重新检测。"
        case .system(EACCES), .system(EPERM): "Mac 无法访问这个串口，请检查设备访问权限。"
        case .system(ENOENT), .system(ENXIO), .system(EIO), .disconnected: "USB 设备已断开。请检查数据线，再重新连接。"
        case let .system(code): "USB 串口错误（\(String(cString: strerror(code)))）。"
        case .timeout: "设备响应超时。请确认已刷入 Camdevice 固件，并关闭其他串口程序。"
        case .invalidResponse: "USB 响应不完整或格式异常。请关闭拍照终端和串口监视器，再重试。"
        case .updateRequired: "请更新相机固件后再清理闪存照片。"
        case .cleanupUnconfirmed: "未收到清理结果。请检查 USB 连接，重新检测相机。"
        case let .device(message): message
        }
    }
}

private final class SerialConnection {
    private let fd: Int32
    private var pending = Data()

    init(port: String) throws {
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC | O_EXLOCK)
        guard fd >= 0 else { throw SerialCameraError.system(errno) }
        guard ioctl(fd, TIOCEXCL) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SerialCameraError.system(code)
        }
        do {
            var settings = termios()
            guard tcgetattr(fd, &settings) == 0 else { throw SerialCameraError.system(errno) }
            cfmakeraw(&settings)
            settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
            settings.c_cflag &= ~tcflag_t(HUPCL)
            guard cfsetspeed(&settings, speed_t(B115200)) == 0,
                  tcsetattr(fd, TCSANOW, &settings) == 0,
                  tcflush(fd, TCIFLUSH) == 0 else { throw SerialCameraError.system(errno) }
        } catch {
            _ = ioctl(fd, TIOCNXCL)
            Darwin.close(fd)
            throw error
        }
        self.fd = fd
    }

    deinit {
        _ = ioctl(fd, TIOCNXCL)
        Darwin.close(fd)
    }

    func send(_ command: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        try Data((command + "\n").utf8).withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try wait(for: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: sent), bytes.count - sent)
                if count > 0 { sent += count }
                else if count == 0 { throw SerialCameraError.disconnected }
                else if errno != EINTR && errno != EAGAIN { throw SerialCameraError.system(errno) }
            }
        }
    }

    func line(until deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 20) throws -> String {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let length = pending.distance(from: pending.startIndex, to: newline)
                guard length <= 1024 else { throw SerialCameraError.invalidResponse }
                let bytes = pending.prefix(length)
                let line = String(decoding: bytes.last == 13 ? bytes.dropLast() : bytes, as: UTF8.self)
                pending.removeFirst(length + 1)
                return line
            }
            guard pending.count <= 1024 else { throw SerialCameraError.invalidResponse }
            try fill(until: deadline)
        }
    }

    func copy(_ count: Int, to file: FileHandle) throws {
        var remaining = count
        while remaining > 0 {
            if pending.isEmpty { try fill(until: ProcessInfo.processInfo.systemUptime + 20) }
            let length = min(remaining, pending.count)
            try file.write(contentsOf: pending.prefix(length))
            pending.removeFirst(length)
            remaining -= length
        }
    }

    private func fill(until deadline: TimeInterval) throws {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try wait(for: Int16(POLLIN), until: deadline)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                pending.append(contentsOf: bytes.prefix(count))
                return
            }
            if count == 0 { throw SerialCameraError.disconnected }
            if errno != EINTR && errno != EAGAIN { throw SerialCameraError.system(errno) }
        }
    }

    private func wait(for events: Int16, until deadline: TimeInterval) throws {
        var port = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SerialCameraError.timeout }
            let ready = poll(&port, 1, Int32((remaining * 1000).rounded(.up)))
            if ready > 0 {
                if port.revents & events != 0 { return }
                throw SerialCameraError.disconnected
            }
            if ready == 0 { throw SerialCameraError.timeout }
            if errno != EINTR { throw SerialCameraError.system(errno) }
        }
    }
}
