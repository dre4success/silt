import CoreServices
import Foundation

/// Turns a scan into findings. Every rule names exact places (or exact patterns, like a
/// `node_modules` next to a `package.json`) instead of guessing from names alone, and says
/// in one sentence why its items are safe or why they need a look.
public enum Rules {
    static let day: Double = 86_400

    struct Context {
        let r: ScanResult
        let h: String
        let now: Date

        func node(_ rel: String) -> Node? { r.node(at: h + "/" + rel) }

        func item(_ n: Node, label: String? = nil, note: String? = nil, preselected: Bool,
                  removal: Removal = .trash) -> FindingItem {
            let p = r.path(of: n)
            return FindingItem(path: p, label: label ?? r.display(p), bytes: n.reclaimable,
                               lastChange: n.newestDate, note: note, preselected: preselected, removal: removal)
        }

        func ageDays(_ n: Node) -> Double { now.timeIntervalSince1970 / Rules.day - Double(n.newest) / Rules.day }

        func daysSince(_ date: Date?) -> Double { date.map { now.timeIntervalSince($0) / Rules.day } ?? 0 }

        /// Where `walkUserArea` begins: home, or the scanned folder when that's inside home.
        var userAreaStart: Node? {
            if let home = r.node(at: h) { return home }
            // A scan of ~/Library (or ~/.nvm, or a bundle) holds app data, not your files.
            let root = r.rootPath
            guard Scanner.isUserArea(root, home: h) else { return nil }
            let rel = String(root.dropFirst(h.count + 1))
            let caches = ["go"] + Rules.packageCacheTable.map(\.0)
            if caches.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { return nil }
            return r.root
        }

        /// Your own folders: below home, outside ~/Library, hidden folders, bundles, build output
        /// and package caches (Go keeps its module cache in a plain-looking `~/go`).
        func walkUserArea(_ visit: (Node) -> Bool) {
            guard let start = userAreaStart else { return }
            var skip = Set<ObjectIdentifier>()
            for rel in ["Library", "go"] + Rules.packageCacheTable.map(\.0) {
                if let n = node(rel) { skip.insert(ObjectIdentifier(n)) }
            }
            func go(_ n: Node) {
                for c in n.children {
                    if skip.contains(ObjectIdentifier(c)) || c.flags.contains(.hidden) || c.flags.contains(.package) || c.artifact != nil { continue }
                    if visit(c), c.isDirectory { go(c) }
                }
            }
            go(start)
        }
    }

    static let minimum: Int64 = 1_000_000

    static func finding(_ id: String, _ title: String, _ detail: String, _ safety: Safety, _ items: [FindingItem]) -> Finding? {
        let kept = items.filter { $0.bytes >= minimum }
        return kept.isEmpty ? nil : Finding(id: id, title: title, detail: detail, safety: safety, items: kept)
    }

    /// Everything that only needs the tree. Milliseconds, even after a whole-disk scan.
    public static func immediate(_ r: ScanResult, now: Date = Date()) -> [Finding] {
        let c = Context(r: r, h: r.home, now: now)
        return [derivedData(c), deviceSupport(c), simulatorCaches(c), simulators(c), packageCaches(c), appCaches(c),
                aerials(c), androidImages(c), logs(c), buildArtifacts(c), deviceUpdates(c), mailDownloads(c), androidEmulators(c),
                installers(c), oldDownloads(c), untouchedFolders(c), deviceBackups(c), xcodeArchives(c),
                toolchains(c)].compactMap { $0 }
    }

    // MARK: Rebuilds itself

    static func derivedData(_ c: Context) -> Finding? {
        guard let dd = c.node("Library/Developer/Xcode/DerivedData") else { return nil }
        let items = dd.children.filter(\.isDirectory).map { n in
            c.item(n, label: projectName(fromDerivedData: n.name), note: "built \(Format.age(n.newestDate, now: c.now))", preselected: true)
        }
        return finding("xcode-derived-data", "Xcode build products",
                       "Xcode recreates DerivedData the next time you build.", .rebuildable, items)
    }

    /// `Silt-abcdefghijklmnopqrstuvwxyzab` → `Silt`.
    static func projectName(fromDerivedData name: String) -> String {
        guard let dash = name.lastIndex(of: "-") else { return name }
        let suffix = name[name.index(after: dash)...]
        return suffix.count == 28 && suffix.allSatisfy(\.isLowercase) ? String(name[..<dash]) : name
    }

    static func deviceSupport(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            guard let folder = c.node("Library/Developer/Xcode/\(platform) DeviceSupport") else { continue }
            // Keep the newest one per platform ticked off: it's the device you use now.
            let newest = folder.children.max { $0.newest < $1.newest }
            for n in folder.children where n.isDirectory {
                items.append(c.item(n, label: "\(platform) \(n.name)", note: n === newest ? "most recent" : "last used \(Format.age(n.newestDate, now: c.now))",
                                    preselected: n !== newest))
            }
        }
        return finding("xcode-device-support", "Device debugging symbols",
                       "Xcode fetches them again the next time you debug on that device.", .rebuildable, items)
    }

    static func simulatorCaches(_ c: Context) -> Finding? {
        guard let n = c.node("Library/Developer/CoreSimulator/Caches") else { return nil }
        return finding("simulator-caches", "Simulator caches", "The iOS Simulator rebuilds these when it starts.",
                       .rebuildable, [c.item(n, preselected: true)])
    }

    /// Download caches of package managers: (path below home, name, command if trashing won't work).
    /// Two are listed but never ticked, because each can hold something that exists nowhere else.
    static let unticked: [String: String] = [
        ".m2/repository": "may hold libraries you installed locally with mvn install",
        "Library/Caches/JetBrains": "also holds the IDEs' Local History of your edits",
    ]

    static let packageCacheTable: [(String, String, KnownCommand?)] = [
        (".npm/_cacache", "npm", nil), (".npm/_npx", "npx", nil),
        ("Library/Caches/Yarn", "Yarn", nil), ("Library/pnpm/store", "pnpm store", nil),
        (".local/share/pnpm/store", "pnpm store", nil), (".pnpm-store", "pnpm store", nil),
        ("Library/Caches/pnpm", "pnpm", nil), (".bun/install/cache", "Bun", nil),
        ("Library/Caches/pip", "pip", nil), (".cache/pip", "pip", nil), (".cache/uv", "uv", nil),
        ("Library/Caches/pypoetry", "Poetry", nil), ("Library/Caches/Homebrew", "Homebrew downloads", nil),
        ("Library/Caches/CocoaPods", "CocoaPods", nil), (".gradle/caches", "Gradle", nil),
        (".gradle/wrapper/dists", "Gradle wrappers", nil), (".m2/repository", "Maven", nil),
        (".cargo/registry/cache", "Cargo downloads", nil), (".cargo/registry/src", "Cargo sources", nil),
        (".cargo/git/checkouts", "Cargo git checkouts", nil), ("Library/Caches/go-build", "Go build cache", nil),
        // Go marks its module cache read-only, so the Trash can't take it; Go's own command can.
        ("go/pkg/mod", "Go modules", .goModuleCache),
        ("Library/Caches/ms-playwright", "Playwright browsers", nil), (".cache/puppeteer", "Puppeteer browsers", nil),
        ("Library/Caches/electron", "Electron downloads", nil), ("Library/Caches/node-gyp", "node-gyp headers", nil),
        ("Library/Caches/deno", "Deno", nil), (".pub-cache", "Dart pub", nil), (".nuget/packages", "NuGet", nil),
        ("Library/Caches/JetBrains", "JetBrains IDE caches", nil), ("Library/Caches/typescript", "TypeScript", nil),
        ("Library/Caches/org.carthage.CarthageKit", "Carthage", nil), (".cache/pre-commit", "pre-commit", nil),
        (".cache/node/corepack", "Corepack", nil), ("Library/Caches/com.apple.dt.Xcode", "Xcode's own cache", nil),
    ]

    static var claimedCacheNames: Set<String> {
        Set(packageCacheTable.compactMap { rel, _, _ in
            rel.hasPrefix("Library/Caches/") ? String(rel.dropFirst("Library/Caches/".count)) : nil
        })
    }

    static func packageCaches(_ c: Context) -> Finding? {
        var seen = Set<ObjectIdentifier>()
        let items: [FindingItem] = packageCacheTable.compactMap { rel, name, command in
            guard let n = c.node(rel), seen.insert(ObjectIdentifier(n)).inserted else { return nil }
            // `go clean -modcache` clears $GOMODCACHE; only offer it when that's the folder measured here.
            if command == .goModuleCache && goModuleCache(home: c.h) != c.r.path(of: n) { return nil }
            let warning = unticked[rel]
            let note = warning ?? command.map { "cleared by running \($0.display)" } ?? c.r.display(c.r.path(of: n))
            return c.item(n, label: name, note: note, preselected: warning == nil, removal: command.map { .command($0) } ?? .trash)
        }
        return finding("package-caches", "Package manager downloads",
                       "Copies of packages you've already installed. They download again if a project needs them.",
                       .rebuildable, items)
    }

    static func goModuleCache(home: String) -> String? {
        guard let go = KnownCommand.goModuleCache.executable(home: home),
              let out = Shell.run(go, ["env", "GOMODCACHE"], timeout: 10), out.status == 0 else { return nil }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appCaches(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        let claimed = claimedCacheNames
        if let caches = c.node("Library/Caches") {
            for n in caches.children where n.isDirectory && !claimed.contains(n.name) {
                let owner = cacheOwner(n.name)
                items.append(c.item(n, label: owner.label, note: owner.note, preselected: owner.tick))
            }
        }
        // Sandboxed apps keep their caches inside their container.
        if let containers = c.node("Library/Containers") {
            for container in containers.children where container.isDirectory {
                guard let n = container.child(named: "Data")?.child(named: "Library")?.child(named: "Caches") else { continue }
                let owner = cacheOwner(container.name)
                items.append(c.item(n, label: owner.label + " (sandboxed)", note: owner.note, preselected: owner.tick))
            }
        }
        items += chromiumCaches(c)
        return finding("app-caches", "App caches",
                       "Apps rebuild their caches as they need them. Quit an app first for a clean start.",
                       .rebuildable, items.filter { $0.bytes >= 5_000_000 })
    }

    /// Electron apps (Slack, VS Code, Claude…) are Chromium inside, and keep Chromium's caches in
    /// Application Support rather than ~/Library/Caches. A folder only counts when it sits beside
    /// Chromium's own `Local Storage`, so an unrelated folder that happens to be called `Cache` is left alone.
    static let chromiumCacheNames = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                                     "DawnWebGPUCache", "GrShaderCache", "ShaderCache", "CachedData", "CachedExtensionVSIXs"]

    static func chromiumCaches(_ c: Context) -> [FindingItem] {
        guard let support = c.node("Library/Application Support") else { return [] }
        var items: [FindingItem] = []
        for app in support.children where app.isDirectory && !app.name.hasPrefix("com.apple.") {
            var parts: [Node] = []
            func look(_ n: Node, depth: Int) {
                let path = c.r.path(of: n)
                if FileManager.default.fileExists(atPath: path + "/Local Storage") || FileManager.default.fileExists(atPath: path + "/Session Storage") {
                    parts += n.children.filter { chromiumCacheNames.contains($0.name) }
                    if let sw = n.child(named: "Service Worker") { parts += sw.children.filter { $0.name == "CacheStorage" || $0.name == "ScriptCache" } }
                }
                if depth < 3 { for child in n.children where child.isDirectory && child.allocated >= 5_000_000 { look(child, depth: depth + 1) } }
            }
            look(app, depth: 0)
            guard !parts.isEmpty else { continue }
            let paths = parts.map { c.r.path(of: $0) }
            let bytes = parts.reduce(0) { $0 + $1.reclaimable }
            let newest = parts.map(\.newest).max() ?? 0
            items.append(FindingItem(path: paths[0], label: "\(app.name) (web cache)", bytes: bytes,
                                     lastChange: Date(timeIntervalSince1970: TimeInterval(newest)),
                                     note: parts.count > 1 ? "\(parts.count) cache folders" : parts[0].name,
                                     preselected: true, companions: Array(paths.dropFirst())))
        }
        return items
    }

    /// The aerial wallpapers and screen savers macOS has downloaded, minus the ones in use.
    static func aerials(_ c: Context) -> Finding? {
        let base = c.h + "/Library/Application Support/com.apple.wallpaper"
        guard let videos = c.r.node(at: base + "/aerials/videos") else { return nil }
        let inUse = aerialAssetsInUse(indexPath: base + "/Store/Index.plist")
        let files = videos.children.filter { !$0.isDirectory }
        let items = files.filter { !inUse.contains(($0.name as NSString).deletingPathExtension) }
            .map { c.item($0, label: "Aerial video \($0.name.prefix(8))", note: "downloaded \(Format.age($0.newestDate, now: c.now))", preselected: true) }
        // The store can name an aerial that was never downloaded, so only claim one was kept if it was.
        let kept = items.count < files.count ? " The one you're using is kept." : ""
        return finding("aerials", "Downloaded aerial wallpapers",
                       "Videos for aerial wallpapers and screen savers. macOS downloads one again if you choose it, and fetches others by itself, so some may come back.\(kept)",
                       .rebuildable, items)
    }

    /// The wallpaper store nests a binary plist per choice; each carries an `assetID`.
    static func aerialAssetsInUse(indexPath: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: indexPath),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        var ids = Set<String>()
        func visit(_ v: Any) {
            if let d = v as? [String: Any] {
                if let id = d["assetID"] as? String { ids.insert(id) }
                d.values.forEach(visit)
            } else if let a = v as? [Any] {
                a.forEach(visit)
            } else if let blob = v as? Data, let inner = try? PropertyListSerialization.propertyList(from: blob, format: nil) {
                visit(inner)
            }
        }
        visit(root)
        return ids
    }

    /// Simulators are only any use with Xcode. Without it they're dead weight; with it, the ones
    /// not booted in six months are worth a look.
    static func simulators(_ c: Context) -> Finding? {
        guard let devices = c.node("Library/Developer/CoreSimulator/Devices") else { return nil }
        let hasXcode = appName(forBundleID: "com.apple.dt.Xcode") != nil
            || ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).contains { $0.hasPrefix("Xcode") }
        let items: [FindingItem] = devices.children.filter(\.isDirectory).compactMap { n in
            let path = c.r.path(of: n)
            let info = NSDictionary(contentsOfFile: path + "/device.plist")
            let name = info?["name"] as? String ?? n.name
            // `com.apple.CoreSimulator.SimRuntime.iOS-26-1` → `iOS 26.1`
            let runtime = (info?["runtime"] as? String)?.split(separator: ".").last.map { tail -> String in
                let bits = tail.split(separator: "-")
                return bits.first.map { "\($0) " + bits.dropFirst().joined(separator: ".") } ?? String(tail)
            } ?? ""
            let booted = info?["lastBootedAt"] as? Date
            if hasXcode && c.daysSince(booted ?? n.newestDate) < 180 { return nil }
            return FindingItem(path: path, label: "\(name) \(runtime)".trimmingCharacters(in: .whitespaces), bytes: n.reclaimable,
                               lastChange: booted, note: booted.map { "last started \(Format.age($0, now: c.now))" } ?? "never started",
                               preselected: !hasXcode)
        }
        return hasXcode
            ? finding("simulators", "Simulators you haven't started in six months",
                      "Xcode can make a fresh one in a few seconds.", .review, items)
            : finding("simulators", "iOS Simulator devices",
                      "Xcode isn't installed, so nothing can run these. Xcode makes new ones if you install it again.", .rebuildable, items)
    }

    /// Android system images, keeping every one an emulator is built on.
    static func androidImages(_ c: Context) -> Finding? {
        guard let images = c.node("Library/Android/sdk/system-images") else { return nil }
        let used = androidImagesInUse(c)
        var items: [FindingItem] = []
        for api in images.children where api.isDirectory {
            for variant in api.children where variant.isDirectory && !used.contains("\(api.name)/\(variant.name)") {
                items.append(c.item(variant, label: "\(api.name) · \(variant.name)", note: "no emulator uses it", preselected: true))
            }
        }
        return finding("android-images", "Android system images no emulator uses",
                       "Android Studio's SDK Manager downloads them again if you make an emulator that needs one.", .rebuildable, items)
    }

    /// `image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/` → `android-34/google_apis`.
    static func androidImagesInUse(_ c: Context) -> Set<String> {
        let avd = c.h + "/.android/avd"
        var used = Set<String>()
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: avd)) ?? [] where entry.hasSuffix(".avd") {
            guard let text = try? String(contentsOfFile: "\(avd)/\(entry)/config.ini", encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("image.sysdir") {
                let parts = line.split(separator: "=", maxSplits: 1).last?.split(separator: "/") ?? []
                if parts.count >= 3, parts[0] == "system-images" { used.insert("\(parts[1])/\(parts[2])") }
            }
        }
        return used
    }

    static func androidEmulators(_ c: Context) -> Finding? {
        guard let avd = c.node(".android/avd") else { return nil }
        let items = avd.children.filter { $0.isDirectory && $0.name.hasSuffix(".avd") }.map { n -> FindingItem in
            let path = c.r.path(of: n)
            let ini = (path as NSString).deletingPathExtension + ".ini"
            return FindingItem(path: path, label: (n.name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " "),
                               bytes: n.reclaimable, lastChange: n.newestDate,
                               note: "last run \(Format.age(n.newestDate, now: c.now))", preselected: false,
                               companions: FileManager.default.fileExists(atPath: ini) ? [ini] : [])
        }
        return finding("android-emulators", "Android emulators",
                       "Each emulator's disk. Android Studio can make a fresh one, but its installed apps and data go with it.", .review, items)
    }

    /// Browsers whose cache folders aren't named by bundle ID.
    static let knownCacheOwners: Set<String> = ["Google", "Mozilla", "BraveSoftware", "Microsoft Edge", "Firefox",
                                                "Vivaldi", "com.operasoftware.Opera", "Arc", "Chromium"]

    /// Only caches that can be pinned on a non-Apple app are ticked. macOS keeps some of its
    /// own under plain names (CloudKit, GeoServices, PassKit), so a name Silt can't place is
    /// listed but left alone.
    static func cacheOwner(_ name: String) -> (label: String, tick: Bool, note: String?) {
        if name.hasPrefix("com.apple.") { return (name, false, "macOS's own; left unticked") }
        // Squirrel, the updater many Electron apps use, stages downloads in `<bundle id>.ShipIt`.
        if name.hasSuffix(".ShipIt"), let app = appName(forBundleID: String(name.dropLast(".ShipIt".count))) {
            return ("\(app) updates", true, "downloaded updates")
        }
        let reverseDNS = name.split(separator: ".").count >= 3 && !name.contains(" ")
        if reverseDNS {
            if let app = appName(forBundleID: name) { return (app, true, nil) }
            return (name, true, "its app isn't installed")
        }
        if knownCacheOwners.contains(name) { return (name, true, nil) }
        return (name, false, "couldn't tell which app owns it; left unticked")
    }

    /// `com.spotify.client` → `Spotify`, via Launch Services.
    static func appName(forBundleID id: String) -> String? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL],
              let url = urls.first else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func logs(_ c: Context) -> Finding? {
        guard let n = c.node("Library/Logs") else { return nil }
        let items = n.children.map { c.item($0, label: $0.name, preselected: true) }
        return finding("logs", "Logs and crash reports", "Diagnostic records apps write as they run. Nothing reads them back.",
                       .rebuildable, items)
    }

    static func buildArtifacts(_ c: Context) -> Finding? {
        let items: [FindingItem] = c.r.artifacts.compactMap { n in
            guard let kind = n.artifact, let project = n.parent else { return nil }
            // npm, Yarn and pnpm each leave a marker in a node_modules they installed. Tools that
            // ship their own dependencies (npm inside nvm, editor extensions) don't, and stay put.
            if kind == .nodeModules {
                let path = c.r.path(of: n)
                let markers = [".package-lock.json", ".yarn-integrity", ".modules.yaml", ".yarn-state.yml"]
                guard markers.contains(where: { FileManager.default.fileExists(atPath: path + "/" + $0) }) else { return nil }
            }
            let active = Date(timeIntervalSince1970: TimeInterval(project.newestSource))
            let stale = c.now.timeIntervalSince(active) > 30 * day
            let label = c.r.display(c.r.path(of: n))
            return FindingItem(path: c.r.path(of: n), label: label, bytes: n.reclaimable, lastChange: active,
                               note: "\(project.name) last changed \(Format.age(active, now: c.now)) · \(kind.restore) brings it back",
                               preselected: stale)
        }
        return finding("build-artifacts", "Project build output",
                       "node_modules, Rust targets and the like. Ticked ones belong to projects you haven't touched in a month.",
                       .rebuildable, items)
    }

    static func deviceUpdates(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        for folder in ["Library/iTunes/iPhone Software Updates", "Library/iTunes/iPad Software Updates"] {
            items += c.node(folder)?.children.map { c.item($0, preselected: true) } ?? []
        }
        return finding("device-updates", "iPhone and iPad updates", "Downloaded system updates. Finder fetches them again if needed.",
                       .rebuildable, items)
    }

    static func mailDownloads(_ c: Context) -> Finding? {
        guard let n = c.node("Library/Containers/com.apple.mail/Data/Library/Mail Downloads") else { return nil }
        return finding("mail-downloads", "Mail attachment copies",
                       "Copies Mail made when you opened attachments; the originals stay in your mail. If you edited one and saved it, that edit lives only here.",
                       .review, [c.item(n, preselected: false)])
    }

    // MARK: Check first

    static func installers(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        let downloads = c.node("Downloads")
        c.walkUserArea { n in
            if !n.isDirectory && Classifier.isInstaller(n.name) {
                let old = c.daysSince(n.arrivedOrChanged) > 30
                let inDownloads = downloads.map { n.isDescendant(of: $0) } ?? false
                let path = c.r.path(of: n)
                var note = "arrived \(Format.age(n.arrivedOrChanged, now: c.now))"
                var tick = old && inDownloads
                let lower = path.lowercased()
                if tick && lower.hasSuffix(".iso") {
                    // People keep ISOs on purpose, to install a virtual machine from.
                    tick = false
                    note += " · often kept for virtual machines"
                } else if tick && lower.hasSuffix(".dmg") && !isInstallerImage(path) {
                    tick = false
                    note += " · a writable or encrypted image, so it may hold your own files"
                }
                items.append(c.item(n, label: c.r.display(path), note: note, preselected: tick))
            }
            return true
        }
        return finding("installers", "Installers and disk images",
                       "Once an app is installed, its .dmg or .pkg isn't needed. Ticked ones are installers in Downloads over a month old.",
                       .review, items)
    }

    /// Installers ship as compressed, read-only, unencrypted images. Anything else may be a
    /// disk image someone keeps files in. `-stdinpass` with an empty stdin makes an encrypted
    /// image fail at once instead of waiting about 30 s for a password nobody can type.
    static func isInstallerImage(_ path: String) -> Bool {
        guard let out = Shell.run("/usr/bin/hdiutil", ["imageinfo", "-plist", "-stdinpass", path], timeout: 15), out.status == 0,
              let info = try? PropertyListSerialization.propertyList(from: Data(out.stdout.utf8), format: nil) as? [String: Any],
              let format = info["Format"] as? String else { return false }
        let encrypted = (info["Properties"] as? [String: Any])?["Encrypted"] as? Bool ?? true
        return ["UDZO", "ULFO", "ULMO", "UDBZ", "UDCO", "UDRO"].contains(format) && !encrypted
    }

    static func oldDownloads(_ c: Context) -> Finding? {
        guard let dl = c.node("Downloads") else { return nil }
        // Installers are their own finding; listing them twice would double the total.
        let items = dl.children.filter { c.daysSince($0.arrivedOrChanged) > 180 && !Classifier.isInstaller($0.name) }
            .map { c.item($0, label: $0.name, note: "arrived \(Format.age($0.arrivedOrChanged, now: c.now))", preselected: false) }
        return finding("old-downloads", "Old downloads", "Things in Downloads that haven't changed in six months.", .review, items)
    }

    static func untouchedFolders(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        let keep = Set(["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications"].compactMap { c.node($0).map(ObjectIdentifier.init) })
        let downloads = c.node("Downloads")
        c.walkUserArea { n in
            guard n.isDirectory, n !== downloads else { return false }
            if n.allocated >= 1_000_000_000 && c.ageDays(n) > 730 && !keep.contains(ObjectIdentifier(n)) {
                let year = Calendar.current.component(.year, from: n.newestDate ?? c.now)
                items.append(c.item(n, note: "nothing inside has changed since \(year)", preselected: false))
                return false
            }
            return n.allocated >= 1_000_000_000
        }
        return finding("untouched-folders", "Folders untouched for two years",
                       "Large folders where nothing has changed in over two years. Worth archiving or letting go.", .review, items)
    }

    static func deviceBackups(_ c: Context) -> Finding? {
        guard let backups = c.node("Library/Application Support/MobileSync/Backup") else { return nil }
        let items = backups.children.filter(\.isDirectory).map { n -> FindingItem in
            let path = c.r.path(of: n)
            let info = NSDictionary(contentsOfFile: path + "/Info.plist")
            let name = info?["Device Name"] as? String ?? n.name
            let date = info?["Last Backup Date"] as? Date ?? n.newestDate
            return FindingItem(path: path, label: "\(name) backup", bytes: n.reclaimable, lastChange: date,
                               note: "backed up \(Format.age(date, now: c.now))", preselected: false)
        }
        return finding("device-backups", "iPhone and iPad backups",
                       "Local backups made by Finder. Check the device backs up to iCloud before removing.", .review, items)
    }

    static func xcodeArchives(_ c: Context) -> Finding? {
        guard let archives = c.node("Library/Developer/Xcode/Archives") else { return nil }
        let items = archives.children.flatMap(\.children).filter { $0.name.hasSuffix(".xcarchive") }
            .map { c.item($0, label: $0.name, note: "archived \(Format.age($0.newestDate, now: c.now))", preselected: false) }
        return finding("xcode-archives", "Xcode archives",
                       "Builds you archived for release. Keep the ones you need to read crash reports from.", .review, items)
    }

    /// Old Node versions under nvm and Rust toolchains under rustup, keeping the defaults.
    static func toolchains(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        if let versions = c.node(".nvm/versions/node") {
            let alias = (try? String(contentsOfFile: c.h + "/.nvm/alias/default", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wanted = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
            let all = versions.children.filter(\.isDirectory)
            let newest = all.max { versionKey($0.name).lexicographicallyPrecedes(versionKey($1.name)) }
            for n in all {
                let v = String(n.name.dropFirst())
                let isDefault = !wanted.isEmpty && Double(wanted.prefix(1)) != nil && (v == wanted || v.hasPrefix(wanted + "."))
                if isDefault || n === newest { continue }
                items.append(c.item(n, label: "Node \(n.name)", note: "nvm install \(n.name) brings it back", preselected: false))
            }
        }
        if let toolchains = c.node(".rustup/toolchains") {
            let settings = (try? String(contentsOfFile: c.h + "/.rustup/settings.toml", encoding: .utf8)) ?? ""
            for n in toolchains.children where n.isDirectory && !settings.contains("\"\(n.name)\"") {
                items.append(c.item(n, label: "Rust \(n.name)", note: "rustup toolchain install \(n.name) brings it back", preselected: false))
            }
        }
        return finding("toolchains", "Old toolchain versions",
                       "Node and Rust versions other than your defaults. Some projects may still pin one.", .review, items)
    }

    static func versionKey(_ name: String) -> [Int] {
        name.drop { !$0.isNumber }.split(separator: ".").map { Int($0) ?? 0 }
    }

    // MARK: Slower checks

    /// Uses Spotlight's "last opened" date, about a millisecond per file.
    public static func unused(_ r: ScanResult, now: Date = Date()) -> [Finding] {
        let c = Context(r: r, h: r.home, now: now)
        return [largeUnopenedFiles(c), unusedApps(c)].compactMap { $0 }
    }

    static func largeUnopenedFiles(_ c: Context) -> Finding? {
        var items: [FindingItem] = []
        c.walkUserArea { n in
            if !n.isDirectory, n.allocated >= 500_000_000, c.ageDays(n) > 365, !Classifier.isInstaller(n.name) {
                let path = c.r.path(of: n)
                let used = Spotlight.lastUsed(path)
                if let used, c.now.timeIntervalSince(used) < 365 * day { return true }
                let note = used.map { "last opened \(Format.age($0, now: c.now))" } ?? "no record of being opened · changed \(Format.age(n.newestDate, now: c.now))"
                items.append(FindingItem(path: path, label: c.r.display(path), bytes: n.reclaimable,
                                         lastChange: used ?? n.newestDate, note: note, preselected: false))
            }
            return n.isDirectory && n.allocated >= 500_000_000
        }
        return finding("large-unopened", "Large files you haven't opened in a year",
                       "Half a gigabyte or more each, and Spotlight hasn't seen them opened in over a year.", .review, items)
    }

    static func unusedApps(_ c: Context) -> Finding? {
        var apps: [Node] = []
        for folder in ["/Applications", c.h + "/Applications"] {
            guard let n = c.r.node(at: folder) else { continue }
            for a in n.children where a.isDirectory {
                if a.name.hasSuffix(".app") { apps.append(a) }
                else if !a.flags.contains(.package) { apps += a.children.filter { $0.name.hasSuffix(".app") } }
            }
        }
        let items: [FindingItem] = apps.compactMap { a in
            // Not the age of the bundle: auto-updaters keep rewriting apps nobody opens.
            guard a.allocated >= 50_000_000, a.name != "Silt.app" else { return nil }
            let path = c.r.path(of: a)
            guard Spotlight.displayName(path) != nil else { return nil }   // not indexed: no evidence either way
            let used = Spotlight.lastUsed(path)
            if let used, c.now.timeIntervalSince(used) < 180 * day { return nil }
            if used == nil, c.daysSince(a.added > 0 ? Date(timeIntervalSince1970: TimeInterval(a.added)) : nil) < 180 { return nil }
            let note = used.map { "last opened \(Format.age($0, now: c.now))" } ?? "no record of being opened since it was installed"
            return FindingItem(path: path, label: (a.name as NSString).deletingPathExtension, bytes: a.reclaimable,
                               lastChange: used, note: note, preselected: false)
        }
        return finding("unused-apps", "Apps you haven't opened in six months",
                       "Going by Spotlight's record of when each app was last opened.", .review, items)
    }

    /// Docker keeps its images in a disk image, invisible to a file scan, so ask Docker.
    public static func docker(home: String = NSHomeDirectory()) -> [Finding] {
        guard let exe = KnownCommand.dockerBuildCache.executable(home: home),
              let context = KnownCommand.localDockerContext(exe),
              let out = Shell.run(exe, ["--context", context, "system", "df", "--format", "{{json .}}"], timeout: 15),
              out.status == 0 else { return [] }
        var reclaimable: [String: Int64] = [:]
        for line in out.stdout.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let type = obj["Type"], let text = obj["Reclaimable"] else { continue }
            reclaimable[type] = parseDockerSize(text)
        }
        var findings: [Finding] = []
        if let b = reclaimable["Build Cache"], let f = finding("docker-build-cache", "Docker build cache",
                "Layers kept to speed up docker build. The next build recreates what it needs.", .rebuildable,
                [FindingItem(path: "command:docker-build-cache", label: "Build cache", bytes: b, lastChange: nil,
                             note: "cleared by running \(KnownCommand.dockerBuildCache.display)", preselected: true,
                             removal: .command(.dockerBuildCache))]) {
            findings.append(f)
        }
        if let i = reclaimable["Images"], let f = finding("docker-images", "Unused Docker images",
                "Images no container is using. Ones from a registry come back with docker pull; ones you built or loaded yourself would need rebuilding. Volumes, which hold data, are left alone.", .review,
                [FindingItem(path: "command:docker-images", label: "Images not used by any container", bytes: i, lastChange: nil,
                             note: "cleared by running \(KnownCommand.dockerImages.display)", preselected: false,
                             removal: .command(.dockerImages))]) {
            findings.append(f)
        }
        return findings
    }

    /// `5.296GB (74%)` → 5_296_000_000. Docker prints decimal units.
    static func parseDockerSize(_ text: String) -> Int64 {
        let s = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where s.hasSuffix(u) {
            return Int64((Double(s.dropLast(u.count)) ?? 0) * m)
        }
        return 0
    }
}
