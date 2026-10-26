import CoreServices
import Foundation

/// "Last opened" comes from Spotlight, not the file system. APFS only refreshes a file's
/// access time when it's older than the modification time (checked on this machine), so
/// `atime` says "read at least once since it changed", not when.
public enum Spotlight {
    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    public static func displayName(_ path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemDisplayName) as? String
    }
}
