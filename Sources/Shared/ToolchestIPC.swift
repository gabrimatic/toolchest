// The private channels between Toolchest and its extensions, compiled into all of them.
//
// For each channel Toolchest opens a Mach message port and writes a fresh random secret to an
// owner-only file at every start. A sandboxed extension may look up only its port and read only
// its secret file (its sandbox exceptions), and must present the secret with every request. Web
// pages and sandboxed apps can reach neither, and Toolchest rejects any message whose secret doesn't
// match.
import Foundation

enum ToolchestIPC {
    static let messageID: Int32 = 1

    /// The user's real home folder, also from inside the sandbox.
    static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Constant-time comparison, so timing doesn't leak how much of a guess was right.
    static func secretsMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Every message starts with the secret.
    struct Envelope: Decodable { var secret: String }

    static func readSecret(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends `body` to the port and returns the reply, or nil when Toolchest isn't listening.
    static func send(_ body: Data, to portName: String, timeout: TimeInterval = 2) -> Data? {
        guard let port = CFMessagePortCreateRemote(nil, portName as CFString) else { return nil }
        defer { CFMessagePortInvalidate(port) }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, messageID, body as CFData, timeout, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else { return nil }
        return reply?.takeRetainedValue() as Data?
    }
}

/// Finder extension → Toolchest.
enum FinderIPC {
    static let portName = "info.gabrimatic.toolchest.finder-ipc"
    /// Relative to the user's real home folder (not the extension's container).
    static let secretRelativePath = "Library/Application Support/Toolchest/IPC/finder.secret"
    static var secretURL: URL { URL(fileURLWithPath: ToolchestIPC.realHome).appendingPathComponent(secretRelativePath) }

    struct Message: Codable, Equatable, Sendable {
        var secret: String
        var action: String
        var paths: [String]
        var label: Int?
    }

    enum Reply: UInt8, Sendable {
        case accepted = 1
        case rejected = 2
    }

    static func secretsMatch(_ a: String, _ b: String) -> Bool { ToolchestIPC.secretsMatch(a, b) }
}

/// Widgets and Control Center controls → Toolchest.
enum WidgetIPC {
    static let portName = "info.gabrimatic.toolchest.widget-ipc"
    static let secretRelativePath = "Library/Application Support/Toolchest/IPC/widget.secret"
    static var secretURL: URL { URL(fileURLWithPath: ToolchestIPC.realHome).appendingPathComponent(secretRelativePath) }

    enum Command: String, Codable, Sendable {
        case state, keepAwakeOn, keepAwakeOff, micMute, micUnmute, nextOutput, cleaning, hyperOn, hyperOff
    }

    struct Request: Codable, Equatable, Sendable {
        var secret: String
        var command: Command
        /// Keep Awake duration in minutes; nil means until turned off.
        var minutes: Int?
    }

    /// What widgets and controls show. `error` is set when Toolchest refused the command.
    struct State: Codable, Equatable, Sendable {
        var keepAwakeAvailable = false
        var keepAwakeOn = false
        var keepAwakeUntil: Date?
        var micAvailable = false
        var micMuted = false
        var outputName: String?
        var outputSymbol: String?
        var inputName: String?
        var cleaningAvailable = false
        var hyperAvailable = false
        var hyperOn = false
        var error: String?
    }

    /// Asks Toolchest. nil when Toolchest isn't running or the secret can't be read.
    static func ask(_ command: Command, minutes: Int? = nil) -> State? {
        guard let secret = ToolchestIPC.readSecret(secretURL),
              let body = try? JSONEncoder().encode(Request(secret: secret, command: command, minutes: minutes)),
              let reply = ToolchestIPC.send(body, to: portName) else { return nil }
        return try? JSONDecoder().decode(State.self, from: reply)
    }
}
