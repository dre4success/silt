import Foundation

/// The boot disk is two volumes since Catalina: a sealed read-only system volume at `/`
/// and a writable Data volume at `/System/Volumes/Data`. Folders such as `/Users` and
/// `/Applications` are "firmlinks" from the system volume into Data.
///
/// Silt scans the Data volume directly (one device, nothing counted twice) and uses this
/// map to show and act on the familiar paths: `Users/you/x` on Data is `/Users/you/x`.
public struct PathMap: Sendable {
    public static let dataVolume = "/System/Volumes/Data"

    /// What the scanner opened.
    public let ioRoot: String
    /// Firmlink targets relative to the Data volume, e.g. `Users`, `usr/local`. Empty when
    /// the scan root is an ordinary folder.
    let firmlinks: [String]

    public init(ioRoot: String) {
        self.ioRoot = ioRoot
        self.firmlinks = ioRoot == Self.dataVolume ? Self.readFirmlinks() : []
    }

    public var isWholeDisk: Bool { ioRoot == Self.dataVolume }

    static func readFirmlinks() -> [String] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            return ["Users", "Applications", "Library", "opt", "private", "usr/local", "Volumes", "cores"]
        }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            return parts.count == 2 ? String(parts[1]) : nil
        }
    }

    /// The path a person (and Finder) would use for something `rel` below the scan root.
    public func path(forRelative rel: String) -> String {
        guard isWholeDisk else { return rel.isEmpty ? ioRoot : ioRoot + "/" + rel }
        if rel.isEmpty { return "/" }
        if firmlinks.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { return "/" + rel }
        return ioRoot + "/" + rel
    }

    /// The inverse: where `path` sits below the scan root, or nil if it's outside it.
    public func relative(forPath path: String) -> String? {
        if path == ioRoot { return "" }
        if path.hasPrefix(ioRoot + "/") { return String(path.dropFirst(ioRoot.count + 1)) }
        guard isWholeDisk else { return nil }
        if path == "/" { return "" }
        let rel = String(path.dropFirst())
        return firmlinks.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) ? rel : nil
    }
}
