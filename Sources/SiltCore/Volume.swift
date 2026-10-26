import Foundation

/// How the boot disk's space is split up, before any scanning.
public struct VolumeInfo: Sendable {
    public var name = "Macintosh HD"
    /// The APFS container: every volume on it shares this pool.
    public var capacity: Int64 = 0
    public var free: Int64 = 0
    /// Free plus what macOS can purge by itself (iCloud copies, caches it manages, snapshots).
    public var freeIncludingPurgeable: Int64 = 0
    /// The Data volume, which holds everything you can see and change.
    public var dataUsed: Int64 = 0
    /// The sealed macOS volume plus Preboot, Recovery, VM (swap) and Update.
    public var systemUsed: Int64 = 0

    public var purgeable: Int64 { max(0, freeIncludingPurgeable - free) }

    public init() {}

    public static func current() -> VolumeInfo {
        var v = VolumeInfo()
        let url = URL(fileURLWithPath: "/")
        if let r = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                     .volumeAvailableCapacityKey,
                                                     .volumeAvailableCapacityForImportantUsageKey]) {
            v.name = r.volumeName ?? v.name
            v.capacity = Int64(r.volumeTotalCapacity ?? 0)
            v.free = Int64(r.volumeAvailableCapacity ?? 0)
            v.freeIncludingPurgeable = r.volumeAvailableCapacityForImportantUsage ?? v.free
        }
        if let apfs = apfsUsage() {
            v.dataUsed = apfs.data
            v.systemUsed = apfs.system
            v.capacity = apfs.capacity
            v.free = apfs.free
        } else {
            v.dataUsed = max(0, v.capacity - v.free)
        }
        return v
    }

    /// `diskutil apfs list -plist` is the one place that reports each volume's share of the container.
    static func apfsUsage() -> (capacity: Int64, free: Int64, data: Int64, system: Int64)? {
        var fs = statfs()
        guard statfs(PathMap.dataVolume, &fs) == 0 else { return nil }
        let device = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let dataID = device.replacingOccurrences(of: "/dev/", with: "")
        guard let out = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 10), out.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(out.stdout.utf8), format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        for c in containers {
            let volumes = c["Volumes"] as? [[String: Any]] ?? []
            guard volumes.contains(where: { $0["DeviceIdentifier"] as? String == dataID }) else { continue }
            var data: Int64 = 0, system: Int64 = 0
            for vol in volumes {
                let used = (vol["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                if vol["DeviceIdentifier"] as? String == dataID { data = used } else { system += used }
            }
            let capacity = (c["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0
            let free = (c["CapacityFree"] as? NSNumber)?.int64Value ?? 0
            return (capacity, free, data, system)
        }
        return nil
    }
}
