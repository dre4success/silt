import AppKit
import Observation
import SiltCore
import SwiftUI

enum ScanTarget: Hashable {
    case wholeDisk, home, folder(String)

    var path: String {
        switch self {
        case .wholeDisk: PathMap.dataVolume
        case .home: AppModel.home
        case .folder(let p): p
        }
    }

    var title: String {
        switch self {
        case .wholeDisk: "Whole disk"
        case .home: "Home folder"
        case .folder(let p): (p as NSString).lastPathComponent
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case kind = "Kind", age = "Age"
    var id: Self { self }
}

struct DiskSegment: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
    var hatched = false
}

struct CleanupReport {
    enum Tone { case done, note, problem }
    var text: String
    var failures: [RemovalOutcome] = []
    var trashed: [URL] = []
    var tone: Tone = .done
}

/// Programs using files that are about to go, or that are stuck in the Trash. Apps are named,
/// because you can quit them; background services only counted, because a restart is the fix.
struct InUse: Equatable {
    var apps: [String] = []
    var services = 0
    var isEmpty: Bool { apps.isEmpty && services == 0 }
}

/// Everything the window shows. Lives on the main actor; the scan, the rules and every
/// removal run elsewhere and hand their results back here.
@MainActor @Observable
final class AppModel {
    var target: ScanTarget = .wholeDisk
    var volume = VolumeInfo()
    var scanning = false
    var live = ScanProgressSnapshot()
    var scanStarted = Date()
    var result: ScanResult?
    /// Bumped whenever the tree changes in place (nodes are classes, so SwiftUI can't see it).
    var revision = 0
    var findings: [Finding] = []
    var checksRunning: [String] = []
    var selected: Set<String> = []
    var expanded: Set<String> = []
    var focus: Node?
    var hovered: Node?
    var colorMode: ColorMode = .kind
    /// What's in the Trash: measured by the scan, plus what Silt moved there since, and measured
    /// again after every Empty Trash, because Finder can leave some of it behind.
    var trashBytes: Int64 = 0
    var hasFullDiskAccess = true
    var working: String?
    var report: CleanupReport?
    var askToClear = false
    /// What the open Clear dialog describes. Frozen when it opens, so a check that finishes
    /// meanwhile can't add something the dialog didn't mention.
    var pendingClear: [FindingItem] = []
    var keptDuplicates = 0
    /// Who is using any of `pendingClear`, found before the dialog opens.
    var pendingInUse = InUse()
    /// Ticked items the open Clear dialog holds back to keep a last copy; unticked once it runs.
    @ObservationIgnored private var heldBack: Set<String> = []
    /// Every set of identical files this scan found, keeper first. Kept apart from the findings,
    /// which lose rows as things are cleared, so a copy stays protected after its row is gone.
    @ObservationIgnored private var knownDuplicates: [String: Set<String>] = [:]
    /// Everything cleared since the scan. Members of a duplicate set here count as already going.
    @ObservationIgnored private(set) var clearedPaths: Set<String> = []
    var askToEmptyTrash = false
    var single: FindingItem?
    /// Moving `single` would leave no copy of a duplicated file outside the Trash.
    var singleIsLastCopy = false

    @ObservationIgnored private var progress: ScanProgress?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// `SILT_HOME` lets the snapshot harness treat a scratch folder as home, so the whole
    /// clear-and-report path can be exercised without touching anything real.
    nonisolated static let home = ProcessInfo.processInfo.environment["SILT_HOME"] ?? NSHomeDirectory()
    nonisolated static var isHarness: Bool { ProcessInfo.processInfo.environment["SILT_HOME"] != nil }
    @ObservationIgnored let safety = SafetyGuard(home: AppModel.home)
    @ObservationIgnored var onSettled: (() -> Void)?

    // MARK: Scanning

    func start() {
        let env = ProcessInfo.processInfo.environment
        if let root = env["SILT_ROOT"] { target = root == "~" ? .home : .folder((root as NSString).expandingTildeInPath) }
        scan()
    }

    func scan(_ newTarget: ScanTarget) {
        guard working == nil else { return }
        target = newTarget
        scan()
    }

    func scan() {
        // A clear in flight finishes on the tree it started from (see `apply`), so it goes first.
        guard working == nil else { return }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        scanning = true
        scanStarted = Date()
        live = ScanProgressSnapshot()
        result = nil
        findings = []
        knownDuplicates = [:]
        clearedPaths = []
        selected = []
        expanded = []
        focus = nil
        hovered = nil
        report = nil
        trashBytes = 0
        checksRunning = []
        hasFullDiskAccess = Self.hasFullDiskAccess()
        refreshVolume()

        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.progress === p else { return }
                self.live = p.snapshot
            }
        }

        var options = ScanOptions(root: target.path)
        options.home = Self.home
        Task {
            let r = await Self.run(options, p)
            guard self.progress === p, !p.isCancelled else { return }
            self.poll?.cancel()
            self.live = p.snapshot
            self.result = r
            self.focus = r.root
            self.scanning = false
            self.trashBytes = r.node(at: r.home + "/.Trash")?.allocated ?? 0
            self.checksRunning = ["caches, downloads and build output"]
            let found = await Task.detached { Rules.immediate(r) }.value
            // A rescan or another folder may have replaced this scan while the rules ran.
            guard self.progress === p, self.result === r, !p.isCancelled else { return }
            self.add(found)
            await self.runSlowChecks(r, p)
            guard self.result === r else { return }
            self.onSettled?()
        }
    }

    func stop() {
        progress?.cancel()
        poll?.cancel()
        scanning = false
    }

    /// The scanner blocks while its own threads work, so give it a thread of its own rather
    /// than tying up one of Swift's cooperative ones.
    nonisolated private static func run(_ options: ScanOptions, _ p: ScanProgress) async -> ScanResult {
        await withCheckedContinuation { c in
            let t = Thread { c.resume(returning: Scanner(options: options, progress: p).run()) }
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    private func runSlowChecks(_ r: ScanResult, _ p: ScanProgress) async {
        let harness = Self.isHarness
        checksRunning = harness ? ["apps and old files", "duplicates"] : ["apps and old files", "Docker", "duplicates"]
        await withTaskGroup(of: (String, [Finding]).self) { group in
            group.addTask { ("apps and old files", Rules.unused(r)) }
            // Never ask the real Docker to prune anything from a harness run.
            if !harness { group.addTask { ("Docker", Rules.docker(home: r.home)) } }
            group.addTask {
                let groups = Duplicates.find(r, cancelled: { p.isCancelled })
                return ("duplicates", Duplicates.finding(groups, display: r.display).map { [$0] } ?? [])
            }
            for await (name, found) in group {
                guard self.result === r else { continue }
                self.add(found)
                self.checksRunning.removeAll { $0 == name }
            }
        }
    }

    private func add(_ more: [Finding]) {
        learnDuplicates(from: more)
        findings += more
        for f in more { for i in f.items where i.preselected { selected.insert(i.id) } }
    }

    func refreshVolume() {
        Task {
            let v = await Task.detached { VolumeInfo.current() }.value
            self.volume = v
        }
    }

    func chooseFolder() {
        guard working == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            target = .folder(url.path)
            scan()
        }
    }

    /// TCC guards this file; being able to open it means Full Disk Access is on.
    static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: Derived numbers

    var rebuildable: [Finding] { findings.filter { $0.safety == .rebuildable }.sorted { $0.bytes > $1.bytes } }
    var review: [Finding] { findings.filter { $0.safety == .review }.sorted { $0.bytes > $1.bytes } }

    /// Sums by path so an item listed twice (a big old file that's also a duplicate) counts once.
    func uniqueBytes(_ fs: [Finding]) -> Int64 {
        var seen: [String: Int64] = [:]
        for f in fs { for i in f.items { seen[i.path] = i.bytes } }
        return outermost(Array(seen.keys)).reduce(0) { $0 + (seen[$1] ?? 0) }
    }

    var clearableTotal: Int64 { uniqueBytes(findings) }
    var rebuildableTotal: Int64 { uniqueBytes(rebuildable) }

    /// Drops any path that sits inside another one in the list.
    func outermost(_ paths: [String]) -> [String] {
        let set = Set(paths)
        return paths.filter { p in
            var cur = (p as NSString).deletingLastPathComponent
            while cur.count > 1 {
                if set.contains(cur) { return false }
                cur = (cur as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    var selectedItems: [FindingItem] {
        var byPath: [String: FindingItem] = [:]
        for f in findings { for i in f.items where selected.contains(i.id) { byPath[i.path] = i } }
        return outermost(Array(byPath.keys)).compactMap { byPath[$0] }.sorted { $0.bytes > $1.bytes }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    var diskSegments: [DiskSegment] {
        _ = revision
        // When the Trash is a folder inside the scan, it's shown as one section of its own, so
        // what's in it isn't counted again under its kinds (trashed aerial videos as "Photos,
        // video & music", say). A scan of the Trash itself shows its kinds as usual.
        let trashNode = result.flatMap { r in r.node(at: r.home + "/.Trash").flatMap { $0 === r.root ? nil : $0 } }
        var kinds = result?.root.kinds ?? live.kinds
        if let trashNode { kinds -= trashNode.kinds }
        var out: [DiskSegment] = []
        let whole = target == .wholeDisk
        if whole && volume.systemUsed > 0 {
            out.append(DiskSegment(id: "system", title: "macOS", bytes: volume.systemUsed, color: Palette.system))
        }
        for k in Kind.allCases where kinds[k] > 0 {
            out.append(DiskSegment(id: "kind-\(k.rawValue)", title: k.title, bytes: kinds[k], color: Palette.kind(k)))
        }
        if (whole || trashNode != nil) && trashBytes > 0 {
            out.append(DiskSegment(id: "trash", title: "Waiting in the Trash", bytes: trashBytes,
                                   color: Palette.system, hatched: true))
        }
        if whole {
            let seen = (result?.root.allocated ?? live.bytes) - (trashNode?.allocated ?? 0)
            let unseen = volume.dataUsed - seen - trashBytes
            if unseen > 0 {
                out.append(DiskSegment(id: "unseen", title: scanning ? "Not looked at yet" : "Hidden from Silt",
                                       bytes: unseen, color: Palette.unseen, hatched: true))
            }
            out.append(DiskSegment(id: "free", title: "Free", bytes: volume.free, color: Palette.free))
        }
        return out
    }

    // MARK: Ticking

    func isSelected(_ item: FindingItem) -> Bool { selected.contains(item.id) }

    func toggle(_ item: FindingItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func state(of f: Finding) -> CheckState {
        let n = f.items.filter { selected.contains($0.id) }.count
        return n == 0 ? .off : n == f.items.count ? .on : .mixed
    }

    func toggleAll(_ f: Finding) {
        if state(of: f) == .on { f.items.forEach { selected.remove($0.id) } } else { f.items.forEach { selected.insert($0.id) } }
    }

    // MARK: Clearing

    /// Clearing takes nodes out of the tree, so it waits until nothing else is reading it:
    /// the checks walk the same nodes from background tasks.
    var treeInUse: Bool { scanning || !checksRunning.isEmpty || working != nil }

    func prepareClear() {
        guard !treeInUse else { return }
        let items = selectedItems
        learnDuplicates(from: findings)
        pendingClear = FindingItem.sparingLastCopies(items, sets: duplicateSets, gone: clearedPaths)
        heldBack = Set(items.map(\.id)).subtracting(pendingClear.map(\.id))
        keptDuplicates = heldBack.count
        pendingInUse = InUse()
        askToClear = !pendingClear.isEmpty
        if pendingClear.isEmpty && !heldBack.isEmpty {
            // Everything ticked is a last copy, so there's no dialog to open: say so rather than do nothing.
            let n = heldBack.count
            selected.subtract(heldBack)
            heldBack = []
            report = CleanupReport(text: n == 1
                ? "Nothing cleared: the ticked item holds the last copy of a duplicated file, so it stays. Silt has unticked it."
                : "Nothing cleared: the \(n) ticked items hold the last copies of duplicated files, so they stay. Silt has unticked them.",
                tone: .note)
        }
    }

    /// What the Clear button does: works out what would go, then, before the dialog opens, asks
    /// which programs are using any of it. Finder can't delete a file that's in use, so an app
    /// whose cache goes while it runs keeps the Trash from emptying.
    func requestClear() {
        prepareClear()
        guard askToClear else { return }
        askToClear = false
        let folders = pendingClear.filter(\.isFile).flatMap { [$0.path] + $0.companions }
        working = "Checking whether any app is using these…"
        Task {
            let found = await Task.detached { OpenFiles.holders(under: folders) }.value
            self.pendingInUse = Self.inUse(found)
            self.working = nil
            self.askToClear = true
        }
    }

    struct AppInfo {
        let name: String
        let bundleID: String?
        /// Something you can quit: a Dock app, or a menu-bar app that isn't part of macOS.
        let quittable: Bool
    }

    nonisolated static func runningApp(_ pid: Int32) -> AppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let menuBar = app.activationPolicy == .accessory && !(app.bundleURL?.path.hasPrefix("/System/") ?? true)
        return AppInfo(name: app.localizedName ?? "", bundleID: app.bundleIdentifier,
                       quittable: app.activationPolicy == .regular || menuBar)
    }

    /// Sorts holders into apps you can quit and background services. A helper process counts as
    /// the app that started it (Chrome's network helper is what holds Chrome's cache). Silt is
    /// left out, and so is Finder: what it holds in the Trash is what it's still deleting.
    static func inUse(_ found: OpenFiles.Found, lookup: (Int32) -> AppInfo? = runningApp) -> InUse {
        func owner(_ pid: Int32) -> AppInfo? {
            var p = pid
            for _ in 0..<10 {
                if let app = lookup(p), app.quittable { return app }
                guard let up = found.parents[p], up > 1, up != p else { return nil }
                p = up
            }
            return nil
        }
        var apps = Set<String>(), services = Set<String>()
        for h in found.holders where h.pid != getpid() {
            if let app = owner(h.pid) {
                if app.bundleID != "com.apple.finder" { apps.insert(app.name.isEmpty ? h.command : app.name) }
            } else {
                services.insert(h.command)
            }
        }
        return InUse(apps: apps.sorted(), services: services.count)
    }

    /// "Spotify", "Spotify and WhatsApp", "Claude, ChatGPT, Google Chrome and 4 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2...3: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        default: return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
    }

    func clearSelected() {
        // What the dialog held back stays put, so it shouldn't stay ticked either.
        selected.subtract(heldBack)
        heldBack = []
        perform(pendingClear)
        pendingClear = []
    }

    private func learnDuplicates(from fs: [Finding]) {
        for set in FindingItem.duplicateSets(in: fs) { knownDuplicates[set[0], default: []].formUnion(set.dropFirst()) }
    }

    var duplicateSets: [[String]] { knownDuplicates.keys.sorted().map { [$0] + knownDuplicates[$0]!.sorted() } }

    /// After a clear: remembers what went, so the copies it leaves stay protected, and stops
    /// offering it, along with every listing of a duplicate set it broke.
    func forget(_ gone: Set<String>) {
        learnDuplicates(from: findings)
        clearedPaths.formUnion(gone)
        findings = Finding.dropping(gone, from: findings, sets: duplicateSets)
        selected.formIntersection(Set(findings.flatMap { $0.items.map(\.id) }))
    }

    func confirmSingle(_ node: Node) {
        guard let r = result, !treeInUse else { return }
        let p = r.path(of: node)
        let item = FindingItem(path: p, label: r.display(p), bytes: node.reclaimable, lastChange: node.newestDate, note: nil, preselected: true)
        // A hand-picked move isn't held back, but the dialog says when it takes the last copy.
        learnDuplicates(from: findings)
        singleIsLastCopy = FindingItem.sparingLastCopies([item], sets: duplicateSets, gone: clearedPaths).isEmpty
        single = item
    }

    func refusal(for node: Node) -> String? {
        guard let r = result else { return "no scan" }
        return safety.refusal(for: r.path(of: node))
    }

    func perform(_ items: [FindingItem]) {
        guard !items.isEmpty, let r = result, !treeInUse else { return }
        let commands = items.filter { if case .command = $0.removal { true } else { false } }.count
        working = commands > 0 ? "Clearing \(items.count) items (running \(commands) command\(commands == 1 ? "" : "s"))…"
                               : "Moving \(items.count) item\(items.count == 1 ? "" : "s") to the Trash…"
        let safety = self.safety
        Task {
            let outcomes = await Task.detached { items.map { Remover.perform($0, guard: safety) } }.value
            self.apply(outcomes, in: r)
        }
    }

    /// `r` is still the tree on screen: scans wait while `working` is set, so the trash
    /// accounting and the focus below belong to it.
    private func apply(_ outcomes: [RemovalOutcome], in r: ScanResult) {
        var moved = 0, ran = 0
        var movedBytes: Int64 = 0, freedBytes: Int64 = 0
        var gone = Set<String>()
        for o in outcomes where o.succeeded {
            gone.insert(o.item.path)
            switch o.item.removal {
            case .trash:
                moved += 1
                movedBytes += o.item.bytes
                for p in [o.item.path] + o.item.companions where !FileManager.default.fileExists(atPath: p) {
                    gone.insert(p)
                    if let n = r.node(at: p) { leave(n, in: r); r.detach(n) }
                }
            case .command:
                ran += 1
                freedBytes += o.item.bytes
            case .emptyTrash:
                break
            }
        }
        trashBytes += movedBytes
        forget(gone)
        hovered = nil
        revision += 1

        var parts: [String] = []
        if moved > 0 { parts.append("Moved \(moved) item\(moved == 1 ? "" : "s") (\(Format.bytes(movedBytes))) to the Trash. Empty it to get the space back.") }
        if ran > 0 { parts.append("Freed \(Format.bytes(freedBytes)) by running \(ran) command\(ran == 1 ? "" : "s").") }
        let failures = outcomes.filter { !$0.succeeded }
        if !failures.isEmpty { parts.append("\(failures.count) couldn't be cleared.") }
        report = CleanupReport(text: parts.joined(separator: " "), failures: failures,
                               trashed: outcomes.compactMap(\.trashedTo))
        working = nil
        refreshVolume()
    }

    /// Moves the map out of a node that's about to leave the tree, to the folder that held it.
    private func leave(_ n: Node, in r: ScanResult) {
        if let f = focus, f === n || f.isDescendant(of: n) { focus = n.parent ?? r.root }
        if let h = hovered, h === n || h.isDescendant(of: n) { hovered = nil }
    }

    func emptyTrash() {
        guard !treeInUse else { return }
        working = "Asking Finder to empty the Trash…"
        let before = volume.free
        let r = result
        let trash = (r?.home ?? Self.home) + "/.Trash"
        let item = FindingItem(path: "trash:", label: "Trash", bytes: trashBytes, lastChange: nil, note: nil,
                               preselected: false, removal: .emptyTrash)
        let safety = self.safety
        Task {
            let o = await Task.detached { Remover.perform(item, guard: safety) }.value
            self.working = "Checking what's left in the Trash…"
            let (measured, found, v) = await Task.detached {
                (Self.size(of: trash), OpenFiles.holders(under: [trash]), VolumeInfo.current())
            }.value
            self.volume = v
            let left: Int64? = measured.complete ? measured.bytes : nil
            if let now = Self.trashAfterEmpty(finderSucceeded: o.succeeded, left: left) {
                // Finder may have emptied all of it or only some, so the scan's picture of the
                // Trash is out of date: its contents leave the tree, and the new figure stands in.
                if let r, r === self.result, let node = r.node(at: trash) {
                    node.children.forEach { self.leave($0, in: r); r.detach($0) }
                }
                self.trashBytes = now
                self.revision += 1
            }
            self.report = Self.emptyReport(o, left: left, inUse: Self.inUse(found), freeNow: v.free, freeBefore: before)
            self.working = nil
        }
    }

    /// The space a folder takes, measured the way a scan measures it, and whether all of it
    /// could be read. Without Full Disk Access the Trash may be unreadable, and an unreadable
    /// Trash must not pass for an empty one.
    nonisolated static func size(of folder: String) -> (bytes: Int64, complete: Bool) {
        // Only a folder that's really not there counts as empty; being refused a look
        // (an unreadable folder above it) leaves the measurement incomplete.
        var st = stat()
        if lstat(folder, &st) != 0 { return (0, errno == ENOENT || errno == ENOTDIR) }
        var o = ScanOptions(root: folder)
        o.home = home
        let r = Scanner(options: o, progress: ScanProgress()).run()
        return (r.root.allocated, r.unreadable.isEmpty && !r.root.flags.contains(.unreadable))
    }

    /// What the Trash holds after asking Finder to empty it, or nil to keep the estimate from
    /// before: a full measurement wins; failing that, Finder's word that it emptied it.
    static func trashAfterEmpty(finderSucceeded: Bool, left: Int64?) -> Int64? {
        left ?? (finderSucceeded ? 0 : nil)
    }

    static func emptyReport(_ o: RemovalOutcome, left: Int64?, inUse: InUse, freeNow: Int64, freeBefore: Int64) -> CleanupReport {
        let gained = "\(Format.bytes(freeNow)) free now, up from \(Format.bytes(freeBefore))."
        // Why something is still there, when Silt can tell.
        var why = ""
        if !inUse.apps.isEmpty {
            let one = inUse.apps.count == 1
            why = "\(list(inUse.apps)) \(one ? "is" : "are") using files in it. Quit \(one ? "it" : "them") and empty it again."
            if inUse.services > 0 { why += " Some macOS services are using files there too; restarting your Mac releases those." }
        } else if inUse.services > 0 {
            why = "macOS services are using files in it. Restart your Mac and empty it again."
        }
        let stuck = (left ?? 0) >= 1_000_000

        // A failed request is always reported, however little is left.
        if !o.succeeded {
            var text = o.message.map { "Finder didn't empty the Trash: \($0)" } ?? "Finder didn't empty the Trash."
            if stuck, let left { text += " \(Format.bytes(left)) is in it" + (why.isEmpty ? "." : ": " + why) }
            return CleanupReport(text: text, failures: [o], tone: .problem)
        }
        guard let left else {
            return CleanupReport(text: "Finder emptied the Trash. \(gained) Silt couldn't look inside the Trash to check that nothing was left; that needs Full Disk Access.",
                                 tone: .note)
        }
        guard stuck else { return CleanupReport(text: "Emptied the Trash. " + gained) }
        var text = freeNow > freeBefore ? "Emptied most of the Trash (\(gained.dropLast())), but \(Format.bytes(left)) is still there"
                                        : "\(Format.bytes(left)) is still in the Trash"
        text += why.isEmpty ? ". Finder couldn't delete some of it." : ": " + why
        return CleanupReport(text: text, tone: .problem)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
