import Foundation

/// Build output that a project can recreate with one command.
public enum ArtifactKind: UInt8, Sendable, CaseIterable {
    case nodeModules, nextBuild, frameworkCache, rustTarget, swiftBuild, pods, pythonEnv,
         gradleBuild, gradleCache, dartTool, flutterBuild, terraform, zigCache, cmakeBuild

    public var title: String {
        switch self {
        case .nodeModules: "node_modules"
        case .nextBuild: "Next.js build"
        case .frameworkCache: "framework cache"
        case .rustTarget: "Rust target"
        case .swiftBuild: "Swift .build"
        case .pods: "CocoaPods"
        case .pythonEnv: "Python virtualenv"
        case .gradleBuild: "Gradle build"
        case .gradleCache: "Gradle cache"
        case .dartTool: "Dart tool cache"
        case .flutterBuild: "Flutter build"
        case .terraform: "Terraform providers"
        case .zigCache: "Zig cache"
        case .cmakeBuild: "CMake build"
        }
    }

    /// The command that brings it back.
    public var restore: String {
        switch self {
        case .nodeModules: "npm install"
        case .nextBuild, .frameworkCache: "the next build"
        case .rustTarget: "cargo build"
        case .swiftBuild: "swift build"
        case .pods: "pod install"
        case .pythonEnv: "reinstalling its requirements"
        case .gradleBuild, .gradleCache: "gradle build"
        case .dartTool, .flutterBuild: "flutter pub get"
        case .terraform: "terraform init"
        case .zigCache: "zig build"
        case .cmakeBuild: "cmake --build"
        }
    }
}

/// One directory, or one file big enough to be worth remembering by itself.
/// Smaller files are folded into their directory's `otherBytes`, which keeps a
/// whole-disk scan to a few hundred thousand nodes instead of millions.
///
/// Thread-safety: during a scan each directory node is written by exactly one
/// worker (the one that lists it), and nobody reads the tree until every worker
/// has finished. After that the rules read it from background tasks, and only once
/// every one of them has finished may the main actor change it (`ScanResult.detach`).
/// The compiler can't see that discipline, hence `@unchecked Sendable`.
public final class Node: @unchecked Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let unreadable = Flags(rawValue: 1 << 0)
        public static let artifact = Flags(rawValue: 1 << 1)
        public static let package = Flags(rawValue: 1 << 2)
        public static let hardlinked = Flags(rawValue: 1 << 3)
        public static let dataless = Flags(rawValue: 1 << 4)
        public static let mayShareBlocks = Flags(rawValue: 1 << 5)
        public static let hidden = Flags(rawValue: 1 << 6)
    }

    public let name: String
    /// Children are owned by their parent, so the back pointer must not retain. It's `weak`
    /// because a node can outlive its parent: the window may still hold a folder (in focus,
    /// under the pointer, in the treemap's tiles) when Silt clears the folder above it.
    public internal(set) weak var parent: Node?
    public let isDirectory: Bool
    public internal(set) var children: [Node] = []

    /// Bytes this subtree occupies on disk (allocated blocks, hard links counted once).
    public internal(set) var allocated: Int64 = 0
    /// Bytes APFS would hand back immediately if this subtree were deleted. Lower than
    /// `allocated` when blocks are shared with clones or held by a snapshot.
    public internal(set) var reclaimable: Int64 = 0
    public internal(set) var fileCount: Int = 0
    /// Latest change anywhere inside, in Unix seconds.
    public internal(set) var newest: Int64 = 0
    /// Latest change ignoring build artifacts, so `npm install` doesn't make a project look active.
    public internal(set) var newestSource: Int64 = 0
    /// Sum of bytes × days-since-change, so `ageSum / allocated` is the byte-weighted mean age.
    public internal(set) var ageSum: Double = 0
    public internal(set) var kinds = KindBytes()
    /// Small files and small folders folded into this directory.
    public internal(set) var otherBytes: Int64 = 0
    public internal(set) var otherCount: Int = 0
    public internal(set) var flags: Flags = []
    /// For files: what the file is. For directories: the context inherited from the path, if any.
    public internal(set) var context: Kind?
    public internal(set) var artifact: ArtifactKind?
    /// When it was put in its folder (download, copy, move), in Unix seconds.
    public internal(set) var added: Int64 = 0
    public internal(set) var logicalSize: Int64 = 0
    public internal(set) var inode: UInt64 = 0

    init(name: String, parent: Node?, isDirectory: Bool) {
        self.name = name
        self.parent = parent
        self.isDirectory = isDirectory
    }

    public var kind: Kind { context ?? kinds.dominant }

    public var meanAgeDays: Double { allocated > 0 ? ageSum / Double(allocated) : 0 }

    public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil }

    /// The later of last change and arrival, for "how long has this been sitting here".
    public var arrivedOrChanged: Date? {
        let t = max(newest, added)
        return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }

    public var depth: Int {
        var d = 0
        var p = parent
        while let n = p { d += 1; p = n.parent }
        return d
    }

    public func isDescendant(of other: Node) -> Bool {
        var p = parent
        while let n = p {
            if n === other { return true }
            p = n.parent
        }
        return false
    }

    public func child(named name: String) -> Node? {
        children.first { $0.name == name }
    }
}
