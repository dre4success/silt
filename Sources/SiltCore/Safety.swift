import Foundation

/// The last check before anything leaves its folder. Every removal, whichever rule or
/// click produced it, goes through `refusal(for:)`; a non-nil answer stops it.
///
/// It's deliberately blunt: rather than trying to know what's safe, it knows what must
/// never be touched and refuses anything that is, contains, or sits inside one of those.
/// It judges the path twice: as spelled, and as it really resolves, so a folder that has
/// become a symlink into iCloud Drive can't smuggle a removal there.
public struct SafetyGuard: Sendable {
    public let home: String
    let appBundle: String

    public init(home: String = NSHomeDirectory(), appBundle: String = Bundle.main.bundlePath) {
        self.home = home
        self.appBundle = appBundle
    }

    /// Folders that can't be removed, and can't be removed by removing a parent.
    var keep: [String] {
        let h = home
        return ["/", "/Users", "/Users/Shared", h,
                "/Applications", "/Library", "/System", "/private", "/usr", "/opt", "/bin", "/sbin",
                "/Volumes", "/cores", "/etc", "/var", "/tmp", PathMap.dataVolume,
                h + "/Library", h + "/Library/Caches", h + "/Library/Application Support",
                h + "/Library/Developer", h + "/Library/Developer/Xcode", h + "/Library/Containers",
                h + "/Library/Logs", h + "/Library/Preferences",
                h + "/Documents", h + "/Desktop", h + "/Downloads", h + "/Pictures", h + "/Movies",
                h + "/Music", h + "/Public", h + "/Applications", h + "/.Trash", h + "/.config",
                h + "/.local", h + "/.cache", h + "/.cargo", h + "/.rustup", h + "/.npm", h + "/.nvm",
                h + "/.gradle", h + "/go", h + "/.docker", h + "/.orbstack"]
    }

    /// Nothing below these is ever offered.
    var never: [String] {
        let h = home
        return ["/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/Library/Apple",
                "/Library/Keychains", h + "/Library/Keychains", h + "/.ssh", h + "/.gnupg",
                // Deleting from iCloud Drive or a synced folder deletes it on every device.
                h + "/Library/Mobile Documents", h + "/Library/CloudStorage",
                // Apple's own data stores: Notes, Photos, Mail, Messages, Safari, Contacts, Calendar.
                h + "/Library/Group Containers", h + "/Library/Photos", h + "/Library/Mail",
                h + "/Library/Messages", h + "/Library/Safari", h + "/Library/Accounts",
                h + "/Library/Application Support/AddressBook", h + "/Library/Calendars"]
    }

    public func refusal(for path: String) -> String? {
        if let why = refusalAsSpelled(path) { return why }
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = Self.realpath(parent) else { return "its folder is no longer there" }
        let real = realParent + "/" + (path as NSString).lastPathComponent
        if real != path {
            let resolved = SafetyGuard(home: Self.realpath(home) ?? home, appBundle: appBundle)
            if let why = resolved.refusalAsSpelled(real) { return "it really lives at \(real), and \(why)" }
        }
        var st = stat()
        if lstat(path, &st) != 0 { return "it's no longer there" }
        return nil
    }

    func refusalAsSpelled(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "not an absolute path" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if path.hasSuffix("/") || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "path isn't in canonical form"
        }
        let isApp = (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")) && path.hasSuffix(".app")
        if parts.count < 3 && !(isApp && parts.count == 2) { return "too close to the top of the disk" }

        for k in keep where k == path || k.hasPrefix(path + "/") {
            return "\(k) has to stay"
        }
        for n in never where path.hasPrefix(n + "/") || path == n {
            return "Silt never touches anything in \(n)"
        }
        if appBundle.hasSuffix(".app") && (path == appBundle || appBundle.hasPrefix(path + "/") || path.hasPrefix(appBundle + "/")) {
            return "that's Silt itself"
        }
        // An app's container is its private data; only its caches (and Mail's attachment copies) may go.
        let containers = home + "/Library/Containers/"
        if path.hasPrefix(containers) {
            let inside = path.dropFirst(containers.count).split(separator: "/").dropFirst().map(String.init)
            let allowed = [["Data", "Library", "Caches"], ["Data", "Library", "Mail Downloads"]]
            if !allowed.contains(where: { inside.starts(with: $0) }) {
                return "it's inside an app's private container"
            }
        }
        // A device backup is one unit: a missing file corrupts it.
        let backups = home + "/Library/Application Support/MobileSync/Backup/"
        if path.hasPrefix(backups) && path.dropFirst(backups.count).contains("/") {
            return "it's inside a device backup"
        }
        // Pulling a file out of a bundle (an app, a Photos library, a Scrivener project) breaks it.
        for (i, part) in parts.dropLast().enumerated() {
            let folder = "/" + parts.prefix(i + 1).joined(separator: "/")
            if Self.isBundle(name: String(part), at: folder) {
                return "it's inside \(part), which macOS treats as a single item"
            }
        }
        if !path.hasPrefix(home + "/") && !isApp { return "it's outside your home folder" }
        return nil
    }

    /// Silt's own list first; then Launch Services, which knows every document package an
    /// installed app declares. Code-bundle extensions get the on-disk check instead, because
    /// cache folders are often named after bundle IDs ending in `.app`.
    static func isBundle(name: String, at folder: String) -> Bool {
        if Classifier.isPackage(name) { return Classifier.isRealBundle(name: name, at: folder) }
        guard name.contains("."), !Classifier.isCodeBundleName(name) else { return false }
        return (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
