import Foundation

public struct RemovalOutcome: Sendable {
    public let item: FindingItem
    public let succeeded: Bool
    public let message: String?
    /// Where the Trash put it, for a later "put back".
    public var trashedTo: URL? = nil
}

public enum Remover {
    /// Removes one item. Files go to the Trash (never `removeItem`), so the worst a bad rule
    /// can do is put something in the Trash that you then drag back out.
    public static func perform(_ item: FindingItem, guard safety: SafetyGuard) -> RemovalOutcome {
        switch item.removal {
        case .trash:
            if let reason = safety.refusal(for: item.path) {
                return RemovalOutcome(item: item, succeeded: false, message: "Skipped: \(reason).")
            }
            do {
                var landed: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &landed)
                for extra in item.companions where safety.refusal(for: extra) == nil {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: extra), resultingItemURL: nil)
                }
                return RemovalOutcome(item: item, succeeded: true, message: nil, trashedTo: landed as URL?)
            } catch {
                let ns = error as NSError
                let denied = ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
                return RemovalOutcome(item: item, succeeded: false,
                                      message: denied ? "macOS wouldn't let Silt move it. It may need an administrator, or Full Disk Access."
                                                      : ns.localizedDescription)
            }
        case .command(let command):
            guard let exe = command.executable(home: safety.home) else {
                return RemovalOutcome(item: item, succeeded: false, message: "Couldn't find the tool to run \(command.display).")
            }
            var arguments = command.arguments
            if command == .dockerBuildCache || command == .dockerImages {
                guard let context = KnownCommand.localDockerContext(exe) else {
                    return RemovalOutcome(item: item, succeeded: false, message: "Docker is pointed at another machine, so Silt left it alone.")
                }
                arguments = ["--context", context] + arguments
            }
            guard let out = Shell.run(exe, arguments, timeout: 600) else {
                return RemovalOutcome(item: item, succeeded: false, message: "Couldn't start \(command.display).")
            }
            if out.status == 0 { return RemovalOutcome(item: item, succeeded: true, message: nil) }
            let why = out.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(out.status)"
            return RemovalOutcome(item: item, succeeded: false, message: "\(command.display) failed: \(why)")
        case .emptyTrash:
            return emptyTrash(item)
        }
    }

    /// Finder knows about locked items and every volume's own `.Trashes`; doing it by hand
    /// would also need Full Disk Access, which `~/.Trash` is behind.
    static func emptyTrash(_ item: FindingItem) -> RemovalOutcome {
        // An Apple event times out after two minutes unless told otherwise, and a big Trash takes
        // Finder longer than that; it would carry on deleting while Silt measured and reported.
        let script = ["-e", "with timeout of 600 seconds", "-e", "tell application \"Finder\" to empty trash", "-e", "end timeout"]
        guard let out = Shell.run("/usr/bin/osascript", script, timeout: 620) else {
            return RemovalOutcome(item: item, succeeded: false, message: "Couldn't ask Finder to empty the Trash.")
        }
        if out.status == 0 { return RemovalOutcome(item: item, succeeded: true, message: nil) }
        let message: String
        if out.stderr.contains("-1743") || out.stderr.contains("Not authorized") {
            message = "Silt needs permission to ask Finder. Allow it in System Settings › Privacy & Security › Automation."
        } else if out.stderr.contains("-1712") || out.timedOut {
            message = "Finder is still emptying it after 10 minutes. Give it time, then rescan."
        } else {
            message = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return RemovalOutcome(item: item, succeeded: false, message: message)
    }
}
