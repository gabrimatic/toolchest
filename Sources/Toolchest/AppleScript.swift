import AppKit

/// Runs small AppleScripts. Toolchest never launches the target app just to ask it something: callers
/// check that it is running first.
@MainActor
enum AppleScript {
    enum Failure: Error, Equatable {
        case notPermitted
        case failed(String)
    }

    /// Runs `source` and returns its string result.
    static func run(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("Script did not compile")) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -1743 || number == -1744 { return .failure(.notPermitted) }
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(number)"
            return .failure(.failed(message))
        }
        return .success(result.stringValue ?? "")
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The same check, callable off the main actor.
    nonisolated static func isRunningNow(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Quotes a string for embedding in AppleScript source.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
