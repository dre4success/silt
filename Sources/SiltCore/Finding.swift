import Foundation

public enum Safety: Sendable, Hashable {
    /// Recreated automatically, or with one command, the next time it's needed.
    case rebuildable
    /// Yours. Silt can say it looks unused but can't know you don't want it.
    case review
}

/// The only commands Silt will run. Anything not listed here can't be expressed,
/// so no rule (or bug in one) can make Silt run something else.
public enum KnownCommand: String, Sendable, Hashable, CaseIterable {
    case dockerBuildCache, dockerImages, goModuleCache

    public var display: String {
        switch self {
        case .dockerBuildCache: "docker builder prune --all --force"
        case .dockerImages: "docker image prune --all --force"
        case .goModuleCache: "go clean -modcache"
        }
    }

    var arguments: [String] {
        switch self {
        case .dockerBuildCache: ["builder", "prune", "--all", "--force"]
        case .dockerImages: ["image", "prune", "--all", "--force"]
        case .goModuleCache: ["clean", "-modcache"]
        }
    }

    /// Docker acts on whichever context is current, which could be a server. Silt only runs
    /// it against a context whose endpoint is a local socket, and names that context explicitly.
    static func localDockerContext(_ exe: String) -> String? {
        guard let show = Shell.run(exe, ["context", "show"], timeout: 10), show.status == 0 else { return nil }
        let name = show.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let inspect = Shell.run(exe, ["context", "inspect", name, "--format", "{{.Endpoints.docker.Host}}"], timeout: 10),
              inspect.status == 0,
              inspect.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") else { return nil }
        return name
    }

    func executable(home: String) -> String? {
        switch self {
        case .dockerBuildCache, .dockerImages:
            Shell.firstExecutable(["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.orbstack/bin/docker",
                                   "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
                                   "/Applications/Docker.app/Contents/Resources/bin/docker"])
        case .goModuleCache:
            Shell.firstExecutable(["/usr/local/go/bin/go", "/opt/homebrew/bin/go", "/usr/local/bin/go"])
        }
    }
}

public enum Removal: Sendable, Hashable {
    /// Moved to the Trash: recoverable until the Trash is emptied.
    case trash
    /// Run one of the known commands. Permanent, so only used for things that rebuild.
    case command(KnownCommand)
    /// Ask Finder to empty the Trash. Permanent.
    case emptyTrash
}

public struct FindingItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    /// A file system path, or a `command:` / `trash:` pseudo-path for non-file items.
    public let path: String
    public let label: String
    /// What it frees right away (APFS private size, so clones and snapshots aren't overcounted).
    public let bytes: Int64
    public let lastChange: Date?
    public let note: String?
    public let preselected: Bool
    public let removal: Removal
    /// For a duplicate: the copy being kept. A clear never takes every copy (see `sparingLastCopies`).
    public var keeps: String? = nil
    /// Extra paths that go to the Trash with this one (an emulator's `.ini` beside its folder,
    /// an app's several cache folders shown as one line).
    public let companions: [String]

    public init(path: String, label: String, bytes: Int64, lastChange: Date?, note: String?, preselected: Bool,
                removal: Removal = .trash, companions: [String] = []) {
        self.path = path
        self.label = label
        self.bytes = bytes
        self.lastChange = lastChange
        self.note = note
        self.preselected = preselected
        self.removal = removal
        self.companions = companions
    }

    public var isFile: Bool { removal == .trash }
}

extension FindingItem {
    /// Every set of identical files the duplicates check found, the copy it keeps first.
    /// Read from all findings, not just the ticked items, because the same path can be listed
    /// twice (a big old file that's also a duplicate) and only one listing says what it duplicates.
    public static func duplicateSets(in findings: [Finding]) -> [[String]] {
        var copies: [String: Set<String>] = [:]
        for f in findings { for i in f.items { if let k = i.keeps { copies[k, default: []].insert(i.path) } } }
        return copies.keys.sorted().map { [$0] + copies[$0]!.sorted() }
    }

    /// Holds items back until no set of identical files would lose every member, so Silt can
    /// never take the last copy of a file, whichever findings ticked the copies or the folders
    /// around them. `gone` is what earlier clears took: a member there already counts as going,
    /// so the protection lasts across clears. A ticked copy is held back first, the kept one
    /// last; if no member is ticked by itself, whatever folder would take one is held back.
    public static func sparingLastCopies(_ items: [FindingItem], sets: [[String]], gone: Set<String> = []) -> [FindingItem] {
        var items = items
        func within(_ p: String, _ q: String) -> Bool { p == q || p.hasPrefix(q + "/") }
        func covering(_ p: String) -> Int? {
            items.firstIndex { $0.removal == .trash && ([$0.path] + $0.companions).contains { within(p, $0) } }
        }
        func going(_ p: String) -> Bool { gone.contains { within(p, $0) } || covering(p) != nil }
        for set in sets {
            let order = Array(set.dropFirst()) + [set[0]]
            while set.allSatisfy(going) {
                let direct = order.lazy.compactMap { p in items.firstIndex { $0.path == p } }.first
                // Every member already went in an earlier clear: nothing left to protect.
                guard let i = direct ?? order.lazy.compactMap(covering).first else { break }
                items.remove(at: i)
            }
        }
        return items
    }
}

extension Finding {
    /// What's left to offer once the `gone` paths have left the disk. Items at or inside them
    /// go. So does every listing, in any finding, of a file whose set of identical copies just
    /// lost a member: "same as …" no longer holds, and left ticked, the next clear would take
    /// what may now be the last copy. `sets` defaults to the ones these findings describe.
    public static func dropping(_ gone: Set<String>, from findings: [Finding], sets: [[String]]? = nil) -> [Finding] {
        func isGone(_ p: String) -> Bool { gone.contains(p) || gone.contains { p.hasPrefix($0 + "/") } }
        let broken = Set((sets ?? FindingItem.duplicateSets(in: findings)).filter { $0.contains(where: isGone) }.joined())
        return findings.compactMap { f in
            var f = f
            f.items.removeAll { isGone($0.path) || broken.contains($0.path) }
            return f.items.isEmpty ? nil : f
        }
    }
}

public struct Finding: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let safety: Safety
    public var items: [FindingItem]

    public init(id: String, title: String, detail: String, safety: Safety, items: [FindingItem]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.safety = safety
        self.items = items.sorted { $0.bytes > $1.bytes }
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}
