import Foundation

/// Which programs have files open under some folders. Finder won't delete a file that's in
/// use, so this is what stops the Trash from emptying: an app whose cache went to the Trash
/// while it ran keeps using that cache from inside the Trash.
///
/// `lsof` lists every open file of your own processes in well under a second, and needs no
/// extra permission for them, which is all that matters here.
public enum OpenFiles {
    public struct Holder: Hashable, Sendable {
        public let pid: Int32
        /// The process name as the kernel knows it, which can be cut short ("StocksWid").
        public let command: String

        public init(pid: Int32, command: String) {
            self.pid = pid
            self.command = command
        }
    }

    public struct Found: Sendable {
        public var holders: [Holder] = []
        /// Every listed process's parent, so a helper can be traced to its app: Chromium and
        /// Electron apps open their caches from helper processes, not the app itself.
        public var parents: [Int32: Int32] = [:]

        public init(holders: [Holder] = [], parents: [Int32: Int32] = [:]) {
            self.holders = holders
            self.parents = parents
        }
    }

    public static func holders(under folders: [String]) -> Found {
        guard !folders.isEmpty,
              let out = Shell.run("/usr/sbin/lsof", ["-n", "-w", "-F", "pcnR"], timeout: 15), !out.timedOut else { return Found() }
        // lsof prints resolved paths (/private/var/…, not /var/…), so match those too.
        let resolved = folders.compactMap { SafetyGuard.realpath($0) }
        return parse(out.stdout, under: Array(Set(folders + resolved)))
    }

    /// `-F pcnR` prints one field per line: `p<pid>`, then `R<parent pid>` and `c<command>`,
    /// then an `n<path>` for each open file (and `f<fd>` lines, which are skipped).
    static func parse(_ text: String, under folders: [String]) -> Found {
        var holders = Set<Holder>()
        var parents: [Int32: Int32] = [:]
        var pid: Int32 = 0
        var command = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "R": parents[pid] = Int32(value)
            case "c": command = String(value)
            case "n":
                if folders.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) {
                    holders.insert(Holder(pid: pid, command: command))
                }
            default: break
            }
        }
        return Found(holders: holders.sorted { ($0.command, $0.pid) < ($1.command, $1.pid) }, parents: parents)
    }
}
