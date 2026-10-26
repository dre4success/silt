import CryptoKit
import Darwin
import Foundation

/// Finds files with identical contents, in three narrowing passes so most files are never read:
///   1. same logical size (free: it's in the tree),
///   2. same first and last 64 KB,
///   3. same SHA-256 over the whole file.
/// Before any reading, APFS clones are set aside: two copies made with Finder's Duplicate
/// share one clone ID and one set of blocks, so deleting either frees nothing.
public enum Duplicates {
    public struct Group: Sendable {
        public let keep: String
        public let copies: [(path: String, bytes: Int64)]
        public let size: Int64
    }

    public static func find(_ r: ScanResult, minimumSize: Int64 = 1 << 20, cancelled: @Sendable () -> Bool = { false },
                            status: @Sendable (String) -> Void = { _ in }) -> [Group] {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let c = Rules.Context(r: r, h: r.home, now: Date())
        // The walk judges each folder it enters, but not the one it starts in or those above it,
        // so scanning a repository directly would otherwise list its fixtures.
        guard let start = c.userAreaStart, !insideLeftAlone(r.path(of: start), home: r.home) else { return [] }

        var bySize: [Int64: [Node]] = [:]
        c.walkUserArea { n in
            if n.isDirectory { return !leftAlone(r.path(of: n)) }
            if n.logicalSize >= minimumSize,
               !n.flags.contains(.hardlinked), !n.flags.contains(.dataless) {
                bySize[n.logicalSize, default: []].append(n)
            }
            return true
        }
        var candidates = bySize.values.filter { $0.count > 1 }.map { $0.map { (node: $0, path: r.path(of: $0)) } }
        // Biggest potential savings first, so stopping early still finds what matters.
        candidates.sort { ($0[0].node.logicalSize * Int64($0.count - 1)) > ($1[0].node.logicalSize * Int64($1.count - 1)) }
        status("Comparing \(candidates.reduce(0) { $0 + $1.count }) files that share a size")

        var groups: [Group] = []
        for sameSize in candidates {
            if cancelled() { break }
            let distinct = collapseClones(sameSize)
            guard distinct.count > 1 else { continue }
            let byEnds = Dictionary(grouping: distinct) { endsDigest($0.path) }
            for (ends, set) in byEnds where ends != nil && set.count > 1 {
                let byHash = Dictionary(grouping: set) { fullDigest($0.path) }
                for (hash, same) in byHash where hash != nil && same.count > 1 {
                    let ordered = same.sorted { rank($0.path, home: r.home) < rank($1.path, home: r.home) }
                    let keep = ordered[0]
                    groups.append(Group(keep: keep.path,
                                        copies: ordered.dropFirst().map { ($0.path, $0.node.reclaimable) },
                                        size: keep.node.logicalSize))
                }
            }
        }
        return groups
    }

    static let dependencyFolders: Set<String> = ["node_modules", "site-packages", "venv", "env", "bower_components",
                                                 "Pods", "vendor", "Carthage", "packages"]

    /// Copies inside a git repository are usually there on purpose (fixtures, templates), and
    /// installed dependencies are full of identical files by design.
    static func leftAlone(_ folder: String) -> Bool {
        dependencyFolders.contains((folder as NSString).lastPathComponent)
            || FileManager.default.fileExists(atPath: folder + "/.git")
    }

    /// Whether `path`, or a folder above it short of home, is left alone. Home itself isn't
    /// judged: a `.git` there is a dotfiles repository, not a project of identical fixtures.
    static func insideLeftAlone(_ path: String, home: String) -> Bool {
        var p = path
        while p.hasPrefix(home + "/") {
            if leftAlone(p) { return true }
            p = (p as NSString).deletingLastPathComponent
        }
        return false
    }

    public static func finding(_ groups: [Group], display: (String) -> String) -> Finding? {
        let items = groups.flatMap { g in
            g.copies.map { copy in
                var item = FindingItem(path: copy.path, label: display(copy.path), bytes: copy.bytes, lastChange: nil,
                                       note: "same as \(display(g.keep))", preselected: false)
                item.keeps = g.keep
                return item
            }
        }
        return Rules.finding("duplicates", "Duplicate files",
                             "Byte-for-byte copies, checked with SHA-256. One copy of each is kept and not listed.",
                             .review, items)
    }

    /// Keep the copy outside Downloads, then the one with the shorter path (usually the original,
    /// not "report (1).pdf").
    static func rank(_ path: String, home: String) -> (Int, Int, String) {
        (path.hasPrefix(home + "/Downloads/") ? 1 : 0, path.count, path)
    }

    static func collapseClones(_ files: [(node: Node, path: String)]) -> [(node: Node, path: String)] {
        var seen = Set<UInt64>()
        return files.filter { f in
            guard f.node.flags.contains(.mayShareBlocks), let id = cloneID(f.path), id != 0 else { return true }
            return seen.insert(id).inserted
        }
    }

    static func cloneID(_ path: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_CLONEID)
        var buffer = (UInt32(0), UInt64(0))   // length, then the clone id
        let rc = withUnsafeMutableBytes(of: &buffer) { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard rc == 0 else { return nil }
        return withUnsafeBytes(of: &buffer) { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    static func endsDigest(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let chunk = 64 * 1024
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: chunk)
        for offset in [0, max(0, Int(st.st_size) - chunk)] {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off_t(offset)) }
            guard n >= 0 else { return nil }
            hasher.update(data: buf[0..<n])
        }
        return Data(hasher.finalize())
    }

    static func fullDigest(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Don't push the rest of the system's working set out of memory to hash a video.
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let chunk = 1 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: buf[0..<n])
        }
        return Data(hasher.finalize())
    }
}
