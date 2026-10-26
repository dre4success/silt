import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Folder to scan. Pass `PathMap.dataVolume` for the whole disk.
    public var root: String
    /// Files at least this big get their own node; smaller ones are folded into their folder.
    public var keepFilesFrom: Int64 = 1 << 20
    /// Folders smaller than this are folded into their parent once the scan is done.
    public var foldFoldersBelow: Int64 = 1 << 20
    public var workers = max(4, ProcessInfo.processInfo.activeProcessorCount)
    public var home = NSHomeDirectory()

    public init(root: String) { self.root = root }
}

public struct ScanProgressSnapshot: Sendable {
    public var files = 0
    public var folders = 0
    public var bytes: Int64 = 0
    public var kinds = KindBytes()
    public var unreadable = 0
    public var current = ""

    public init() {}
}

/// Live counters the UI polls while workers run. Workers flush into it once per folder,
/// so the lock is taken about a million times per whole-disk scan, never per file.
public final class ScanProgress: Sendable {
    private let state = Mutex(ScanProgressSnapshot())
    private let stopped = Atomic<Bool>(false)

    public init() {}

    public var snapshot: ScanProgressSnapshot { state.withLock { $0 } }
    public var isCancelled: Bool { stopped.load(ordering: .relaxed) }
    public func cancel() { stopped.store(true, ordering: .relaxed) }

    func flush(files: Int, folders: Int, bytes: Int64, kinds: KindBytes, unreadable: Int, current: String?) {
        state.withLock {
            $0.files += files
            $0.folders += folders
            $0.bytes += bytes
            $0.kinds += kinds
            $0.unreadable += unreadable
            if let current { $0.current = current }
        }
    }
}

/// The scanned tree plus everything the rules need that isn't in it.
public final class ScanResult: @unchecked Sendable {
    public let root: Node
    public let map: PathMap
    public let home: String
    public let startedAt: Date
    public let seconds: Double
    public let files: Int
    public let folders: Int
    public let unreadable: [String]
    public let strata: [Int64]
    public let artifacts: [Node]

    init(root: Node, map: PathMap, home: String, startedAt: Date, seconds: Double, files: Int, folders: Int,
         unreadable: [String], strata: [Int64], artifacts: [Node]) {
        self.root = root
        self.map = map
        self.home = home
        self.startedAt = startedAt
        self.seconds = seconds
        self.files = files
        self.folders = folders
        self.unreadable = unreadable
        self.strata = strata
        self.artifacts = artifacts
    }

    public var rootPath: String { map.path(forRelative: "") }

    public func path(of node: Node) -> String {
        var names: [String] = []
        var n: Node? = node
        while let cur = n, cur.parent != nil {
            names.append(cur.name)
            n = cur.parent
        }
        return map.path(forRelative: names.reversed().joined(separator: "/"))
    }

    public func node(at path: String) -> Node? {
        guard let rel = map.relative(forPath: path) else { return nil }
        var n = root
        for part in rel.split(separator: "/") {
            guard let c = n.child(named: String(part)) else { return nil }
            n = c
        }
        return n
    }

    /// `~/Library/Caches` rather than `/Users/you/Library/Caches`.
    public func display(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Takes a node out of the tree after it has been moved to the Trash, and subtracts it
    /// from every ancestor so totals stay right without a rescan.
    public func detach(_ node: Node) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var p: Node? = parent
        while let n = p {
            n.allocated -= node.allocated
            n.reclaimable -= node.reclaimable
            n.fileCount -= node.fileCount
            n.kinds -= node.kinds
            n.ageSum -= node.ageSum
            n.parent?.children.sort { $0.allocated > $1.allocated }
            p = n.parent
        }
        node.parent = nil
    }
}

/// A parallel directory walker built on `getattrlistbulk(2)`.
///
/// `getattrlistbulk` returns a whole directory's entries *and* their metadata in one
/// syscall, where `FileManager` or `fts` make one `stat` per file. Eight workers share a
/// LIFO stack of folders; LIFO keeps the walk roughly depth-first so the stack stays small.
/// On this machine that reads ~170k entries a second, against ~50k single-threaded.
public final class Scanner: @unchecked Sendable {
    let options: ScanOptions
    let progress: ScanProgress
    let map: PathMap
    let now: Int64
    let rootDevice: dev_t
    /// The home folder as the scanner sees it (Data-volume prefixed on a whole-disk scan).
    let homeIO: String

    private let queue = WorkQueue()
    private let hardlinks = Mutex(Set<UInt64>())
    private let merged = Mutex(Merged())

    struct Merged {
        var files = 0, folders = 0
        var unreadable: [String] = []
        var strata = [Int64](repeating: 0, count: Stratum.allCases.count)
        var artifacts: [Node] = []
    }

    struct Job {
        let node: Node
        let path: String
        let rel: String?        // only tracked near the top, where `Classifier.topLevel` applies
        let depth: Int
        let context: Kind?
        let inPackage: Bool
        let hidden: Bool
        /// True below the home folder, outside ~/Library, hidden folders, bundles and artifacts:
        /// the only places a `node_modules` is assumed to belong to a project of yours.
        let projectArea: Bool
    }

    public init(options: ScanOptions, progress: ScanProgress) {
        self.options = options
        self.progress = progress
        self.map = PathMap(ioRoot: options.root)
        self.now = Int64(Date().timeIntervalSince1970)
        var st = stat()
        lstat(options.root, &st)
        self.rootDevice = st.st_dev
        self.homeIO = map.isWholeDisk ? PathMap.dataVolume + options.home : options.home
    }

    /// Runs the scan on its own threads and blocks until it's done.
    public func run() -> ScanResult {
        let started = Date()
        // iCloud "Optimise Storage" leaves dataless placeholders. Without this, listing or
        // reading one would make macOS download it just so Silt could measure it.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

        let rootName = map.isWholeDisk ? "Macintosh HD" : (options.root as NSString).lastPathComponent
        let root = Node(name: rootName, parent: nil, isDirectory: true)
        queue.push([Job(node: root, path: options.root, rel: map.isWholeDisk ? "" : nil, depth: 0,
                        context: nil, inPackage: false, hidden: false,
                        projectArea: Self.isUserArea(options.root, home: homeIO))])

        let group = DispatchGroup()
        for _ in 0..<options.workers {
            group.enter()
            let t = Thread { [self] in
                worker()
                group.leave()
            }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()

        // Totals roll up from the leaves. Recursion depth equals folder depth, so give it room.
        let finish = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            aggregate(root)
            finish.signal()
        }
        t.stackSize = 64 << 20
        t.start()
        finish.wait()

        let m = merged.withLock { $0 }
        return ScanResult(root: root, map: map, home: options.home, startedAt: started,
                          seconds: Date().timeIntervalSince(started), files: m.files, folders: m.folders,
                          unreadable: m.unreadable.map { visible($0) }, strata: m.strata,
                          artifacts: m.artifacts.filter { $0.parent != nil && $0.allocated >= options.foldFoldersBelow })
    }

    /// True for home and folders below it that aren't in ~/Library, a hidden folder or a bundle.
    /// Scanning `~/.nvm` directly mustn't make npm's own `node_modules` look like a project's.
    static func isUserArea(_ path: String, home: String) -> Bool {
        if path == home { return true }
        guard path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        return parts.first != "Library" && !parts.contains { $0.hasPrefix(".") || Classifier.isPackage(String($0)) }
    }

    func visible(_ ioPath: String) -> String {
        map.relative(forPath: ioPath).map { map.path(forRelative: $0) } ?? ioPath
    }

    // MARK: - Workers

    private func worker() {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var local = Merged()
        var listed = 0
        while let job = queue.next() {
            if !progress.isCancelled {
                list(job, buffer: buffer, bufferSize: bufferSize, into: &local, reportPath: listed % 64 == 0)
            }
            listed += 1
            queue.done()
        }
        merged.withLock { m in
            m.files += local.files
            m.folders += local.folders
            m.unreadable += local.unreadable
            for i in m.strata.indices { m.strata[i] += local.strata[i] }
            m.artifacts += local.artifacts
        }
    }

    private struct Entry {
        var name = ""
        var type: UInt32 = 0
        var device: Int32 = 0
        var modified: Int64 = 0
        var added: Int64 = 0
        var flags: UInt32 = 0
        var fileID: UInt64 = 0
        var mountStatus: UInt32 = 0
        var linkCount: UInt32 = 1
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var privateSize: Int64 = -1
        var extFlags: UInt64 = 0
        var error: UInt32 = 0
    }

    private enum A {
        static let name = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
        static let devid = attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
        static let objtype = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        static let modtime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        static let flags = attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
        static let fileid = attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)
        static let addedtime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ADDEDTIME)
        static let error = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
        static let returned = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        static let mountstatus = attrgroup_t(truncatingIfNeeded: ATTR_DIR_MOUNTSTATUS)
        static let linkcount = attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
        static let allocsize = attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
        static let datalength = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)
        static let privatesize = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE)
        static let extflags = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_EXT_FLAGS)

        static let request: attrlist = {
            var a = attrlist()
            a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            a.commonattr = returned | name | error | devid | objtype | modtime | flags | fileid | addedtime
            a.dirattr = mountstatus
            a.fileattr = linkcount | allocsize | datalength
            // With FSOPT_ATTR_CMN_EXTENDED the fork group carries the "extended common" attributes.
            a.forkattr = privatesize | extflags
            return a
        }()
    }

    /// Lists one folder. Entries come back packed: a length, a bitmap of which attributes were
    /// returned, then each returned attribute in the order of its bit (with ATTR_CMN_ERROR
    /// moved up front). Anything not in the bitmap is simply absent, so every read is guarded.
    private func list(_ job: Job, buffer: UnsafeMutableRawPointer, bufferSize: Int, into local: inout Merged, reportPath: Bool) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            job.node.flags.insert(.unreadable)
            local.unreadable.append(job.path)
            progress.flush(files: 0, folders: 0, bytes: 0, kinds: KindBytes(), unreadable: 1, current: nil)
            return
        }
        defer { close(fd) }

        var request = A.request
        let bulkOptions = UInt64(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        var subfolders: [Node] = []
        var markers: UInt32 = 0
        var files = 0
        var bytes: Int64 = 0
        var kinds = KindBytes()
        let node = job.node

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, bulkOptions)
            if count <= 0 { break }
            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(cursor.load(as: UInt32.self))
                let e = Self.parse(cursor)
                cursor += length

                if e.error != 0 { continue }
                if e.type == VDIR.rawValue {
                    // Skip other volumes and automount triggers (e.g. /System/Volumes/Data/home).
                    let mount = UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)
                    if e.mountStatus & mount != 0 || e.device != rootDevice { continue }
                    let child = Node(name: e.name, parent: node, isDirectory: true)
                    child.newest = clamp(e.modified)
                    child.newestSource = child.newest
                    child.added = clamp(e.added)
                    node.children.append(child)
                    subfolders.append(child)
                } else if e.type == VREG.rawValue || e.type == VLNK.rawValue {
                    markers |= Self.marker(for: e.name)
                    var size = e.allocated
                    var freeable = e.privateSize >= 0 ? e.privateSize : e.allocated
                    if e.linkCount > 1 {
                        // A hard link's blocks are only freed when the last link goes, so
                        // count the bytes once and never promise them back.
                        let first = hardlinks.withLock { $0.insert(e.fileID).inserted }
                        if !first { size = 0 }
                        freeable = 0
                    }
                    // Modification time, as Finder shows it. Not creation time: a copy made
                    // yesterday of a file from 2019 still holds 2019's contents.
                    let changed = clamp(e.modified)
                    let days = Double(max(0, now - changed)) / 86_400
                    let kind = job.context ?? Classifier.kind(ofFile: e.name) ?? .other

                    node.allocated += size
                    node.reclaimable += freeable
                    node.fileCount += 1
                    node.ageSum += Double(size) * days
                    node.kinds[kind] += size
                    node.newest = max(node.newest, changed)
                    node.newestSource = max(node.newestSource, changed)
                    kinds[kind] += size
                    local.strata[Stratum.of(ageDays: days).rawValue] += size
                    files += 1
                    bytes += size

                    if size >= options.keepFilesFrom || e.logical >= options.keepFilesFrom {
                        let f = Node(name: e.name, parent: node, isDirectory: false)
                        f.allocated = size
                        f.reclaimable = freeable
                        f.fileCount = 1
                        f.newest = changed
                        f.newestSource = changed
                        f.added = clamp(e.added)
                        f.ageSum = Double(size) * days
                        f.kinds[kind] = size
                        f.context = kind
                        f.logicalSize = e.logical
                        f.inode = e.fileID
                        if e.linkCount > 1 { f.flags.insert(.hardlinked) }
                        if e.flags & UInt32(truncatingIfNeeded: SF_DATALESS) != 0 { f.flags.insert(.dataless) }
                        if e.extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 { f.flags.insert(.mayShareBlocks) }
                        if job.inPackage { f.flags.insert(.package) }
                        if job.hidden { f.flags.insert(.hidden) }
                        node.children.append(f)
                    } else {
                        node.otherBytes += size
                        node.otherCount += 1
                    }
                }
            }
        }

        // Now that every name in the folder is known, decide what each subfolder is.
        var jobs: [Job] = []
        jobs.reserveCapacity(subfolders.count)
        for child in subfolders {
            let path = job.path + "/" + child.name
            let rel: String? = job.rel.map { $0.isEmpty ? child.name : $0 + "/" + child.name }
            let trackRel = job.depth < 3 ? rel : nil
            // A cache folder named after a bundle ID ends in `.app` too, so a code-bundle name
            // needs a bundle's layout inside. Inside a package everything already counts as one.
            let isPackage = !job.inPackage && Classifier.isPackage(child.name)
                && Classifier.isRealBundle(name: child.name, at: path)
            var context = Classifier.context(forDirectory: child.name, parentName: node.name,
                                             parentContext: job.context, relPath: trackRel, isBundle: isPackage)
            let isHidden = child.name.hasPrefix(".")
            if isPackage || job.inPackage { child.flags.insert(.package) }
            if isHidden || job.hidden { child.flags.insert(.hidden) }

            var projectArea = job.projectArea || path == homeIO
            if job.projectArea, let artifact = Self.artifact(named: child.name, markers: markers) {
                child.artifact = artifact
                child.flags.insert(.artifact)
                context = .developer
                local.artifacts.append(child)
                projectArea = false
            }
            if isHidden || isPackage || path == homeIO + "/Library" { projectArea = false }
            child.context = context
            jobs.append(Job(node: child, path: path, rel: trackRel, depth: job.depth + 1, context: context,
                            inPackage: job.inPackage || isPackage, hidden: job.hidden || isHidden,
                            projectArea: projectArea))
        }
        queue.push(jobs)

        local.files += files
        local.folders += 1
        progress.flush(files: files, folders: 1, bytes: bytes, kinds: kinds, unreadable: 0,
                       current: reportPath ? visible(job.path) : nil)
    }

    private func clamp(_ t: Int64) -> Int64 { min(t, now) }

    private static func parse(_ start: UnsafeRawPointer) -> Entry {
        var e = Entry()
        var f = start + 4
        let returned = f.loadUnaligned(as: attribute_set_t.self)
        f += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        if common & A.error != 0 { e.error = f.loadUnaligned(as: UInt32.self); f += 4 }
        if common & A.name != 0 {
            let ref = f.loadUnaligned(as: attrreference_t.self)
            let namePtr = f + Int(ref.attr_dataoffset)
            let count = max(0, Int(ref.attr_length) - 1)   // length includes the NUL
            e.name = String(decoding: UnsafeRawBufferPointer(start: namePtr, count: count), as: UTF8.self)
            f += MemoryLayout<attrreference_t>.size
        }
        if common & A.devid != 0 { e.device = f.loadUnaligned(as: Int32.self); f += 4 }
        if common & A.objtype != 0 { e.type = f.loadUnaligned(as: UInt32.self); f += 4 }
        if common & A.modtime != 0 { e.modified = Int64(f.loadUnaligned(as: timespec.self).tv_sec); f += MemoryLayout<timespec>.size }
        if common & A.flags != 0 { e.flags = f.loadUnaligned(as: UInt32.self); f += 4 }
        if common & A.fileid != 0 { e.fileID = f.loadUnaligned(as: UInt64.self); f += 8 }
        if common & A.addedtime != 0 { e.added = Int64(f.loadUnaligned(as: timespec.self).tv_sec); f += MemoryLayout<timespec>.size }
        if returned.dirattr & A.mountstatus != 0 { e.mountStatus = f.loadUnaligned(as: UInt32.self); f += 4 }
        if returned.fileattr & A.linkcount != 0 { e.linkCount = f.loadUnaligned(as: UInt32.self); f += 4 }
        if returned.fileattr & A.allocsize != 0 { e.allocated = f.loadUnaligned(as: Int64.self); f += 8 }
        if returned.fileattr & A.datalength != 0 { e.logical = f.loadUnaligned(as: Int64.self); f += 8 }
        if returned.forkattr & A.privatesize != 0 { e.privateSize = f.loadUnaligned(as: Int64.self); f += 8 }
        if returned.forkattr & A.extflags != 0 { e.extFlags = f.loadUnaligned(as: UInt64.self); f += 8 }
        return e
    }

    // MARK: - Build artifacts

    private enum Marker {
        static let packageJSON: UInt32 = 1 << 0
        static let cargo: UInt32 = 1 << 1
        static let swiftPackage: UInt32 = 1 << 2
        static let podfile: UInt32 = 1 << 3
        static let python: UInt32 = 1 << 4
        static let gradle: UInt32 = 1 << 5
        static let pubspec: UInt32 = 1 << 6
        static let terraform: UInt32 = 1 << 7
        static let zig: UInt32 = 1 << 8
        static let cmake: UInt32 = 1 << 9
    }

    private static func marker(for name: String) -> UInt32 {
        switch name {
        case "package.json": Marker.packageJSON
        case "Cargo.toml": Marker.cargo
        case "Package.swift": Marker.swiftPackage
        case "Podfile": Marker.podfile
        case "pyproject.toml", "requirements.txt", "setup.py", "Pipfile": Marker.python
        case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts": Marker.gradle
        case "pubspec.yaml": Marker.pubspec
        case "build.zig": Marker.zig
        case "CMakeLists.txt": Marker.cmake
        default: name.hasSuffix(".tf") ? Marker.terraform : 0
        }
    }

    /// A folder only counts as build output when the project file that produces it sits
    /// beside it: `target` next to `Cargo.toml`, `node_modules` next to `package.json`.
    static func artifact(named name: String, markers m: UInt32) -> ArtifactKind? {
        // Plain `if`s rather than `case a, b where …`: a `where` there guards only the last pattern.
        func needs(_ bit: UInt32, _ kind: ArtifactKind) -> ArtifactKind? { m & bit != 0 ? kind : nil }
        switch name {
        case "node_modules": return needs(Marker.packageJSON, .nodeModules)
        case ".next": return needs(Marker.packageJSON, .nextBuild)
        case ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular": return needs(Marker.packageJSON, .frameworkCache)
        case "target": return needs(Marker.cargo, .rustTarget)
        case ".build": return needs(Marker.swiftPackage, .swiftBuild)
        case "Pods": return needs(Marker.podfile, .pods)
        case ".venv", "venv": return needs(Marker.python, .pythonEnv)
        case "build": return needs(Marker.gradle, .gradleBuild) ?? needs(Marker.pubspec, .flutterBuild)
        case ".gradle": return needs(Marker.gradle, .gradleCache)
        case ".dart_tool": return needs(Marker.pubspec, .dartTool)
        case ".terraform": return needs(Marker.terraform, .terraform)
        case ".zig-cache", "zig-cache": return needs(Marker.zig, .zigCache)
        default: return name.hasPrefix("cmake-build-") ? needs(Marker.cmake, .cmakeBuild) : nil
        }
    }

    // MARK: - Roll-up

    private func aggregate(_ n: Node) {
        for c in n.children where c.isDirectory { aggregate(c) }
        for c in n.children where c.isDirectory {
            n.allocated += c.allocated
            n.reclaimable += c.reclaimable
            n.fileCount += c.fileCount
            n.kinds += c.kinds
            n.ageSum += c.ageSum
            n.newest = max(n.newest, c.newest)
            if c.artifact == nil { n.newestSource = max(n.newestSource, c.newestSource) }
        }
        let fold = options.foldFoldersBelow
        n.children.removeAll { c in
            guard c.isDirectory, c.allocated < fold, !c.flags.contains(.unreadable) else { return false }
            n.otherBytes += c.allocated
            n.otherCount += c.fileCount
            c.parent = nil
            return true
        }
        n.children.sort { $0.allocated > $1.allocated }
    }
}

/// A LIFO stack of folders with a count of folders being listed. The walk is finished
/// when the stack is empty and no worker is mid-folder (which could still push more).
private final class WorkQueue: @unchecked Sendable {
    private var jobs: [Scanner.Job] = []
    private var active = 0
    private let condition = NSCondition()

    func push(_ more: [Scanner.Job]) {
        guard !more.isEmpty else { return }
        condition.lock()
        jobs.append(contentsOf: more)
        condition.broadcast()
        condition.unlock()
    }

    func next() -> Scanner.Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && active > 0 { condition.wait() }
        guard let job = jobs.popLast() else {
            condition.broadcast()
            return nil
        }
        active += 1
        return job
    }

    func done() {
        condition.lock()
        active -= 1
        if active == 0 && jobs.isEmpty { condition.broadcast() }
        condition.unlock()
    }
}
