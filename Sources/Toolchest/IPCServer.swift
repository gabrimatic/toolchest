import Foundation
import Security
import os

/// Toolchest's end of one private extension channel (see ToolchestIPC.swift).
///
/// Each start writes a fresh 256-bit secret (owner-only file in an owner-only folder); stopping
/// invalidates the port and deletes the secret, so a stale secret is never accepted. Only messages
/// that carry the live secret reach `onRequest`.
@MainActor
final class IPCServer {
    private var port: CFMessagePort?
    private(set) var secret: String?
    private let log = Logger(subsystem: "info.gabrimatic.toolchest", category: "ipc")
    private let portName: String
    private let secretURL: URL
    /// Gets the authenticated message and returns the reply.
    var onRequest: (@MainActor (Data) -> Data)?

    init(portName: String, secretURL: URL) {
        self.portName = portName
        self.secretURL = secretURL
    }

    var isRunning: Bool { port != nil }

    /// The reply sent for anything unauthenticated or malformed.
    static let rejection = Data([FinderIPC.Reply.rejected.rawValue])

    static func makeSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the secret owner-only, replacing any older one without following symlinks.
    static func writeSecret(_ secret: String, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch { return false }
        unlink(url.path)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(secret.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }

    func start() {
        guard port == nil else { return }
        guard let secret = Self.makeSecret(), Self.writeSecret(secret, to: secretURL) else {
            log.error("could not create the secret for \(self.portName, privacy: .public)")
            return
        }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        var shouldFree: DarwinBoolean = false
        guard let local = CFMessagePortCreateLocal(nil, portName as CFString, { _, _, data, info in
            guard let info else { return nil }
            let server = Unmanaged<IPCServer>.fromOpaque(info).takeUnretainedValue()
            let bytes = (data as Data?) ?? Data()
            // Delivered on the main run loop.
            let reply = MainActor.assumeIsolated { server.receive(bytes) }
            return Unmanaged.passRetained(reply as CFData)
        }, &context, &shouldFree) else {
            log.error("port \(self.portName, privacy: .public) unavailable (another Toolchest running?)")
            unlink(secretURL.path)
            return
        }
        guard let source = CFMessagePortCreateRunLoopSource(nil, local, 0) else {
            CFMessagePortInvalidate(local)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        port = local
        self.secret = secret
    }

    func stop() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        secret = nil
        unlink(secretURL.path)
    }

    func receive(_ data: Data) -> Data {
        guard let secret, data.count < 512 * 1024,
              let envelope = try? JSONDecoder().decode(ToolchestIPC.Envelope.self, from: data),
              ToolchestIPC.secretsMatch(envelope.secret, secret) else {
            log.notice("rejected a message on \(self.portName, privacy: .public)")
            return Self.rejection
        }
        return onRequest?(data) ?? Self.rejection
    }
}
