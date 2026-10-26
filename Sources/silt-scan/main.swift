import Foundation
import SiltCore

// silt-scan [folder] [--no-duplicates] [--no-docker]
// The engine without the window: scans, runs every rule, prints what it would offer.
// It never removes anything.

var args = Array(CommandLine.arguments.dropFirst())
let skipDuplicates = args.contains("--no-duplicates")
let skipDocker = args.contains("--no-docker")
args.removeAll { $0.hasPrefix("--") }
let root = args.first.map { ($0 as NSString).expandingTildeInPath } ?? PathMap.dataVolume

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func bar(_ fraction: Double, width: Int = 30) -> String { String(repeating: "█", count: max(0, Int((fraction * Double(width)).rounded()))) }

let volume = VolumeInfo.current()
print("\(volume.name): \(Format.bytes(volume.capacity)) · \(Format.bytes(volume.free)) free"
      + (volume.purgeable > 0 ? " (+\(Format.bytes(volume.purgeable)) purgeable)" : ""))
print("  Data volume \(Format.bytes(volume.dataUsed)) · macOS & system volumes \(Format.bytes(volume.systemUsed))\n")

let progress = ScanProgress()
let scanner = Scanner(options: ScanOptions(root: root), progress: progress)
let ticker = Thread {
    while !Thread.current.isCancelled {
        let s = progress.snapshot
        FileHandle.standardError.write("\r  scanning… \(Format.count(s.files)) files, \(Format.bytes(s.bytes))        ".data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.5)
    }
}
ticker.start()
let result = scanner.run()
ticker.cancel()
FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)

let seen = result.root.allocated
print("Scanned \(result.rootPath) in \(String(format: "%.1f", result.seconds)) s: \(Format.count(result.files)) files, \(Format.count(result.folders)) folders")
print("  \(Format.bytes(seen)) on disk, \(Format.bytes(result.root.reclaimable)) of it freeable now (the rest is shared by clones or hard links)")
if result.map.isWholeDisk {
    print("  \(Format.bytes(max(0, volume.dataUsed - seen))) of the Data volume unseen; \(result.unreadable.count) folders unreadable")
}
let unreadableSample = result.unreadable.prefix(6).map { result.display($0) }
if !unreadableSample.isEmpty { print("  e.g. " + unreadableSample.joined(separator: ", ")) }

print("\nBy kind")
for k in Kind.allCases.sorted(by: { result.root.kinds[$0] > result.root.kinds[$1] }) {
    let b = result.root.kinds[k]
    print("  " + pad(k.title, 24) + lpad(Format.bytes(b), 10) + "  " + bar(Double(b) / Double(max(1, seen))))
}

print("\nWhen things last changed")
for s in Stratum.allCases {
    let b = result.strata[s.rawValue]
    print("  " + pad(s.title, 24) + lpad(Format.bytes(b), 10) + "  " + bar(Double(b) / Double(max(1, seen))))
}

print("\nLargest folders")
func biggest(_ n: Node, depth: Int, maxDepth: Int) {
    for c in n.children.prefix(depth == 0 ? 8 : 5) where c.allocated >= 2_000_000_000 {
        print("  " + String(repeating: "  ", count: depth) + pad(c.name, 44 - depth * 2) + lpad(Format.bytes(c.allocated), 10)
              + "  " + Format.ageDays(c.meanAgeDays) .replacingOccurrences(of: " ago", with: "") + " old on average")
        if depth < maxDepth { biggest(c, depth: depth + 1, maxDepth: maxDepth) }
    }
}
biggest(result.root, depth: 0, maxDepth: 3)

var findings = Rules.immediate(result)
let t0 = Date()
findings += Rules.unused(result)
let spotlightTime = Date().timeIntervalSince(t0)
if !skipDocker { findings += Rules.docker() }
var dupTime = 0.0
if !skipDuplicates {
    let t1 = Date()
    let groups = Duplicates.find(result)
    dupTime = Date().timeIntervalSince(t1)
    if let f = Duplicates.finding(groups, display: result.display) { findings.append(f) }
}

for (safety, heading) in [(Safety.rebuildable, "REBUILDS ITSELF"), (.review, "CHECK FIRST")] {
    let group = findings.filter { $0.safety == safety }.sorted { $0.bytes > $1.bytes }
    let total = group.reduce(0) { $0 + $1.bytes }
    let ticked = group.flatMap(\.items).filter(\.preselected).reduce(0) { $0 + $1.bytes }
    print("\n\(heading) — \(Format.bytes(total)) (\(Format.bytes(ticked)) ticked by default)")
    for f in group {
        print("  " + lpad(Format.bytes(f.bytes), 9) + "  \(f.title)  [\(f.items.count) item\(f.items.count == 1 ? "" : "s")]")
        for i in f.items.prefix(4) {
            print("             " + (i.preselected ? "☑ " : "☐ ") + lpad(Format.bytes(i.bytes), 9) + "  " + i.label
                  + (i.note.map { "  — \($0)" } ?? ""))
        }
        if f.items.count > 4 {
            let rest = f.items.dropFirst(4).reduce(0) { $0 + $1.bytes }
            print("                  … \(f.items.count - 4) more, \(Format.bytes(rest))")
        }
    }
}
print(String(format: "\n(Spotlight checks %.1f s, duplicates %.1f s)", spotlightTime, dupTime))
