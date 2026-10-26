import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import Silt
@testable import SiltCore

// MARK: - Fixture

/// A fake home folder on the same APFS volume, so clones, hard links and private sizes behave
/// exactly as they do for real files.
final class Fixture {
    let root: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func file(_ rel: String, mb: Double = 0, byte: UInt8 = 7, daysOld: Double? = nil) throws -> String {
        let path = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Varied bytes so APFS can't compress the file down to nothing.
        var data = Data(count: Int(mb * 1_048_576))
        data.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(byte)) ^ UInt8(truncatingIfNeeded: i >> 9) }
        }
        try data.write(to: URL(fileURLWithPath: path))
        if let daysOld { try age(rel, days: daysOld) }
        return path
    }

    func age(_ rel: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root + "/" + rel)
    }

    func dir(_ rel: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/" + rel, withIntermediateDirectories: true)
    }

    func scan(fold: Int64 = 1) -> ScanResult {
        var o = ScanOptions(root: root)
        o.home = root
        o.foldFoldersBelow = fold
        return Scanner(options: o, progress: ScanProgress()).run()
    }

    func allocated(_ rel: String) -> Int64 {
        var st = stat()
        lstat(root + "/" + rel, &st)
        return Int64(st.st_blocks) * 512
    }
}

// MARK: - Treemap

@Suite struct TreemapTests {
    @Test func areasAreProportionalAndInside() {
        let values: [Double] = [500, 300, 120, 80, 40, 30, 20, 9, 1]
        let rect = CGRect(x: 10, y: 20, width: 640, height: 360)
        let rects = Treemap.squarify(values, in: rect)
        let total = values.reduce(0, +)
        for (v, r) in zip(values, rects) {
            let expected = Double(rect.width * rect.height) * v / total
            #expect(abs(Double(r.width * r.height) - expected) < expected * 0.001 + 0.01)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func tilesStaySquarish() {
        let values = (1...40).map { Double(41 - $0) }
        let rects = Treemap.squarify(values, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        #expect(worst < 4)
    }

    @Test func zerosAndEmptyInput() {
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        let r = Treemap.squarify([5, 0, 5], in: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(r[1] == .zero)
        #expect(abs(r[0].width * r[0].height - 50) < 0.01)
    }
}

// MARK: - Scanner

@Suite struct ScannerTests {
    @Test func sizesMatchStatAndHardLinksCountOnce() throws {
        let fx = try Fixture()
        try fx.file("a/one.bin", mb: 2)
        try fx.file("a/b/two.bin", mb: 3)
        try fx.file("a/b/small.txt", mb: 0.01)
        try FileManager.default.linkItem(atPath: fx.root + "/a/one.bin", toPath: fx.root + "/a/b/one-link.bin")
        try FileManager.default.createSymbolicLink(atPath: fx.root + "/a/link-to-two", withDestinationPath: fx.root + "/a/b/two.bin")

        let r = fx.scan()
        let expected = fx.allocated("a/one.bin") + fx.allocated("a/b/two.bin") + fx.allocated("a/b/small.txt") + fx.allocated("a/link-to-two")
        #expect(r.root.allocated == expected)
        #expect(r.files == 5)
        // A hard-linked file's blocks only come back when every link goes.
        #expect(r.node(at: fx.root + "/a/one.bin")?.reclaimable == 0)
        #expect(r.node(at: fx.root + "/a/b/two.bin")?.reclaimable == fx.allocated("a/b/two.bin"))
        #expect(r.node(at: fx.root + "/a/b/small.txt") == nil)   // folded into its folder
        #expect(r.node(at: fx.root + "/a/b")!.otherCount == 1)
    }

    @Test func clonesShareTheirBlocks() throws {
        let fx = try Fixture()
        try fx.file("orig.bin", mb: 4)
        #expect(clonefile(fx.root + "/orig.bin", fx.root + "/clone.bin", 0) == 0)
        let r = fx.scan()
        let clone = try #require(r.node(at: fx.root + "/clone.bin"))
        #expect(clone.allocated >= 4 * 1_048_576)
        #expect(clone.reclaimable == 0)            // deleting a full clone frees nothing
        #expect(clone.flags.contains(.mayShareBlocks))
        // So the duplicate finder must not offer it either.
        #expect(Duplicates.find(r).isEmpty)
    }

    @Test func realDuplicatesAreFound() throws {
        let fx = try Fixture()
        try fx.file("Documents/report.pdf", mb: 2)
        try fx.file("Downloads/report (1).pdf", mb: 2)
        try fx.file("Documents/other.pdf", mb: 2, byte: 9)   // same size, different bytes
        let groups = Duplicates.find(fx.scan())
        #expect(groups.count == 1)
        #expect(groups[0].keep == fx.root + "/Documents/report.pdf")
        #expect(groups[0].copies.map(\.path) == [fx.root + "/Downloads/report (1).pdf"])
    }

    @Test func duplicatesInsideAGitRepoAreLeftAlone() throws {
        let fx = try Fixture()
        try fx.dir("code/app/.git")
        try fx.file("code/app/fixtures/a.bin", mb: 2)
        try fx.file("code/app/fixtures/b.bin", mb: 2)
        #expect(Duplicates.find(fx.scan()).isEmpty)
    }

    @Test func scanningInsideARepositoryOrDependenciesFindsNoDuplicates() throws {
        let fx = try Fixture()
        try fx.dir("code/app/.git")
        try fx.file("code/app/fixtures/a.bin", mb: 2)
        try fx.file("code/app/fixtures/b.bin", mb: 2)
        try fx.file("web/node_modules/x/big.js", mb: 2)
        try fx.file("web/node_modules/y/big.js", mb: 2)
        for root in ["code/app", "code/app/fixtures", "web/node_modules"] {
            var o = ScanOptions(root: fx.root + "/" + root)
            o.home = fx.root
            o.foldFoldersBelow = 1
            #expect(Duplicates.find(Scanner(options: o, progress: ScanProgress()).run()).isEmpty, "scanning \(root)")
        }
    }

    @Test func aDotfilesRepositoryAtHomeDoesNotHideDuplicates() throws {
        let fx = try Fixture()
        try fx.dir(".git")
        try fx.file("Documents/report.pdf", mb: 2)
        try fx.file("Downloads/report (1).pdf", mb: 2)
        #expect(Duplicates.find(fx.scan()).count == 1)
    }

    @Test func strataUseModificationTime() throws {
        let fx = try Fixture()
        try fx.file("new.bin", mb: 2)
        try fx.file("old.bin", mb: 2, daysOld: 800)
        let r = fx.scan()
        #expect(r.strata[Stratum.week.rawValue] == fx.allocated("new.bin"))
        #expect(r.strata[Stratum.fiveYears.rawValue] == fx.allocated("old.bin"))
    }

    @Test func kindsComeFromContextThenExtension() throws {
        let fx = try Fixture()
        try fx.file("Pictures/beach.jpg", mb: 2)
        try fx.file("Thing.app/Contents/Resources/icon.png", mb: 2)
        try fx.file("Library/Caches/com.example/blob.zip", mb: 2)
        let r = fx.scan()
        #expect(r.node(at: fx.root + "/Pictures/beach.jpg")?.kind == .media)
        #expect(r.node(at: fx.root + "/Thing.app/Contents/Resources/icon.png")?.kind == .apps)
        #expect(r.node(at: fx.root + "/Library/Caches/com.example/blob.zip")?.kind == .caches)
        #expect(r.node(at: fx.root + "/Thing.app")!.flags.contains(.package))
    }

    @Test func buildArtifactsNeedTheirProjectFile() throws {
        let fx = try Fixture()
        try fx.file("code/web/package.json")
        try fx.file("code/web/node_modules/left-pad/index.js", mb: 2)
        try fx.file("code/loose/node_modules/x.js", mb: 2)                       // no package.json beside it
        try fx.file("code/rusty/Cargo.toml")
        try fx.file("code/rusty/target/debug/app", mb: 2)
        try fx.file("Library/Application Support/Code/package.json")
        try fx.file("Library/Application Support/Code/node_modules/ext.js", mb: 2)  // an app's own, not a project
        try fx.file(".nvm/versions/node/v20/lib/package.json")
        try fx.file(".nvm/versions/node/v20/lib/node_modules/npm.js", mb: 2)      // global installs
        let r = fx.scan()
        let found = Set(r.artifacts.map { r.path(of: $0) })
        #expect(found == [fx.root + "/code/web/node_modules", fx.root + "/code/rusty/target"])
    }

    @Test func staleProjectsArePreselected() throws {
        let fx = try Fixture()
        try fx.file("old/package.json", daysOld: 90)
        try fx.file("old/node_modules/a.js", mb: 2)    // freshly installed, but it's the project that counts
        try fx.file("old/node_modules/.package-lock.json")
        try fx.age("old", days: 90)
        try fx.file("fresh/package.json")
        try fx.file("fresh/node_modules/a.js", mb: 2)
        try fx.file("fresh/node_modules/.package-lock.json")
        try fx.file("tool/package.json", daysOld: 400)
        try fx.file("tool/node_modules/dep.js", mb: 2)   // shipped with a tool: no install marker
        try fx.age("tool", days: 400)
        let finding = try #require(Rules.immediate(fx.scan()).first { $0.id == "build-artifacts" })
        let ticked = Set(finding.items.filter(\.preselected).map(\.path))
        #expect(ticked == [fx.root + "/old/node_modules"])
    }

    @Test func detachKeepsTotalsRight() throws {
        let fx = try Fixture()
        try fx.file("a/b/big.bin", mb: 3)
        try fx.file("a/keep.bin", mb: 2)
        let r = fx.scan()
        let before = r.root.allocated
        let big = try #require(r.node(at: fx.root + "/a/b/big.bin"))
        let size = big.allocated
        r.detach(big)
        #expect(r.root.allocated == before - size)
        #expect(r.node(at: fx.root + "/a")!.allocated == before - size)
        #expect(r.node(at: fx.root + "/a/b/big.bin") == nil)
    }

    @Test func aFolderHeldAfterItsParentIsClearedIsSafe() throws {
        let fx = try Fixture()
        try fx.file("a/b/leaf.bin", mb: 2)
        let r = fx.scan()
        let held = try #require(r.node(at: fx.root + "/a/b"))
        weak let cleared = r.node(at: fx.root + "/a")
        r.detach(try #require(cleared))
        // Nothing else kept the cleared folder, so it's gone, and the folder still held
        // reads an empty parent rather than freed memory.
        #expect(cleared == nil)
        #expect(held.parent == nil)
        #expect(!held.isDescendant(of: r.root))
    }

    @Test func onlyRealBundlesCountAsApps() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob.bin", mb: 2)
        try fx.file("Downloads/Real.app/Contents/MacOS/Real", mb: 2)
        let r = fx.scan()
        let cache = try #require(r.node(at: fx.root + "/Library/Caches/com.example.app"))
        let app = try #require(r.node(at: fx.root + "/Downloads/Real.app"))
        #expect(cache.kind == .caches && !cache.flags.contains(.package))
        #expect(app.kind == .apps && app.flags.contains(.package))
    }
}

// MARK: - Rules

@Suite struct ReviewFixTests {
    @Test func scanningInsideAHiddenFolderFindsNoProjects() throws {
        let fx = try Fixture()
        try fx.file(".nvm/versions/node/v20/lib/node_modules/npm/package.json")
        try fx.file(".nvm/versions/node/v20/lib/node_modules/npm/node_modules/abbrev/index.js", mb: 2)
        var o = ScanOptions(root: fx.root + "/.nvm")
        o.home = fx.root
        o.foldFoldersBelow = 1
        let r = Scanner(options: o, progress: ScanProgress()).run()
        #expect(r.artifacts.isEmpty)
    }

    @Test func scanningInsideLibraryOffersNoUserFileRules() throws {
        let fx = try Fixture()
        try fx.file("Library/Application Support/MobileSync/Backup/AAAA/00/file1", mb: 2)
        try fx.file("Library/Application Support/MobileSync/Backup/BBBB/00/file1", mb: 2)
        var o = ScanOptions(root: fx.root + "/Library")
        o.home = fx.root
        let r = Scanner(options: o, progress: ScanProgress()).run()
        #expect(Duplicates.find(r).isEmpty)
    }

    @Test func duplicatesNeverLoseTheLastCopy() {
        func item(_ p: String, keeps: String? = nil) -> FindingItem {
            var i = FindingItem(path: p, label: p, bytes: 1, lastChange: nil, note: nil, preselected: true)
            i.keeps = keeps
            return i
        }
        let copy = item("/u/Downloads/a (1).pdf", keeps: "/u/Old/a.pdf")
        let sets = FindingItem.duplicateSets(in: [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy])])
        #expect(sets == [["/u/Old/a.pdf", "/u/Downloads/a (1).pdf"]])
        #expect(FindingItem.sparingLastCopies([copy], sets: sets).count == 1)
        #expect(FindingItem.sparingLastCopies([copy, item("/u/Old")], sets: sets).map(\.path) == ["/u/Old"])
        #expect(FindingItem.sparingLastCopies([copy, item("/u/Old/a.pdf")], sets: sets).map(\.path) == ["/u/Old/a.pdf"])
        // The copy is inside a folder that's going and can't be held back by itself, so the kept one stays.
        #expect(FindingItem.sparingLastCopies([item("/u/Downloads"), item("/u/Old/a.pdf")], sets: sets).map(\.path) == ["/u/Downloads"])
        // What an earlier clear took counts as going: the kept copy is now the last one.
        #expect(FindingItem.sparingLastCopies([item("/u/Old/a.pdf")], sets: sets, gone: ["/u/Downloads/a (1).pdf"]).isEmpty)
        #expect(FindingItem.sparingLastCopies([item("/u/Old/a.pdf")], sets: sets, gone: ["/u/Downloads"]).isEmpty)
        // Every copy already went: nothing left to hold back, and no endless loop.
        #expect(FindingItem.sparingLastCopies([item("/u/Other")], sets: sets, gone: ["/u/Old", "/u/Downloads"]).count == 1)
    }

    @Test func aCopyListedTwiceIsStillProtected() {
        // The same file is both a duplicate and a big old file; the second listing doesn't say what it copies.
        let kept = FindingItem(path: "/u/Documents/a.bin", label: "a", bytes: 2, lastChange: nil, note: nil, preselected: true)
        var copy = FindingItem(path: "/u/Downloads/a.bin", label: "a", bytes: 2, lastChange: nil, note: nil, preselected: true)
        copy.keeps = kept.path
        let asOldFile = FindingItem(path: copy.path, label: "a", bytes: 2, lastChange: nil, note: nil, preselected: true)
        let findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy]),
                        Finding(id: "large-unopened", title: "", detail: "", safety: .review, items: [kept, asOldFile])]
        let left = FindingItem.sparingLastCopies([kept, asOldFile], sets: FindingItem.duplicateSets(in: findings))
        #expect(left.map(\.path) == [kept.path])
    }
}

@Suite struct ShellTests {
    func script(_ fx: Fixture, _ body: String) throws -> String {
        let path = try fx.file("tool.sh")
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    @Test func aToolThatIgnoresTermIsKilled() throws {
        let fx = try Fixture()
        let start = Date()
        let out = Shell.run(try script(fx, "trap '' TERM\nwhile :; do sleep 0.1; done\n"), [], timeout: 0.2, drainLimit: 0.5)
        #expect(out?.timedOut == true)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func aHelperHoldingThePipeCantHangIt() throws {
        let fx = try Fixture()
        let start = Date()
        // The tool exits at once, but the helper it leaves behind keeps stdout open.
        let out = Shell.run(try script(fx, "sleep 5 &\necho done\n"), [], timeout: 10, drainLimit: 0.5)
        #expect(Date().timeIntervalSince(start) < 3)
        // The tool itself succeeded; only its output may be incomplete.
        #expect(out?.status == 0 && out?.timedOut == false && out?.drained == false)
    }

    @Test func anOrdinaryToolIsUnaffected() throws {
        let fx = try Fixture()
        let out = Shell.run(try script(fx, "echo hello\n"), [])
        #expect(out?.status == 0 && out?.stdout == "hello\n" && out?.timedOut == false && out?.drained == true)
    }
}

@Suite struct OpenFilesTests {
    @Test func parsesLsofFields() {
        let text = "p101\nR1\ncSpotify\nf12\nn/u/.Trash/com.spotify.client/Data/db\np202\nR90\ncCode - Insiders\nf3\nn/u/Projects/x\nf4\nn/u/.Trash\np303\nR1\ncother\nn/u/.Trashy/file\n"
        let found = OpenFiles.parse(text, under: ["/u/.Trash"])
        #expect(found.holders.map(\.pid) == [202, 101])   // sorted by name: "Code - Insiders", then "Spotify"
        #expect(found.holders.map(\.command) == ["Code - Insiders", "Spotify"])
        #expect(found.parents == [101: 1, 202: 90, 303: 1])
    }

    @Test func findsAFileThisProcessHasOpen() throws {
        let fx = try Fixture()
        let path = try fx.file("held/open.bin", mb: 0.1)
        let handle = try #require(FileHandle(forReadingAtPath: path))
        defer { try? handle.close() }
        let found = OpenFiles.holders(under: [fx.root + "/held"])
        #expect(found.holders.contains { $0.pid == getpid() })
        #expect(found.parents[getpid()] == getppid())
        #expect(!OpenFiles.holders(under: [fx.root + "/elsewhere"]).holders.contains { $0.pid == getpid() })
    }
}

@Suite @MainActor struct TrashTests {
    @Test func silsOwnFilesDontCountAndServicesAreCountedNotNamed() {
        let holders = [OpenFiles.Holder(pid: getpid(), command: "Silt"), OpenFiles.Holder(pid: 1, command: "launchd")]
        #expect(AppModel.inUse(OpenFiles.Found(holders: holders)) == InUse(apps: [], services: 1))
    }

    /// Helpers count as the app that started them; menu-bar apps you installed are named;
    /// Finder is left out, because what it holds in the Trash is what it's still deleting.
    @Test func helpersAreTracedToTheirApp() {
        let apps: [Int32: AppModel.AppInfo] = [
            100: .init(name: "Google Chrome", bundleID: "com.google.Chrome", quittable: true),
            300: .init(name: "Finder", bundleID: "com.apple.finder", quittable: true),
            400: .init(name: "OneDrive", bundleID: "com.microsoft.OneDrive", quittable: true),
            500: .init(name: "Notification Centre", bundleID: "com.apple.notificationcenterui", quittable: false),
        ]
        let found = OpenFiles.Found(
            holders: [.init(pid: 101, command: "Google Chrome He"), .init(pid: 102, command: "Google Chrome He"),
                      .init(pid: 200, command: "cloudd"), .init(pid: 300, command: "Finder"),
                      .init(pid: 400, command: "OneDrive"), .init(pid: 500, command: "NotificationCe")],
            parents: [101: 100, 102: 101, 100: 1, 200: 1, 300: 1, 400: 1, 500: 1])
        #expect(AppModel.inUse(found, lookup: { apps[$0] }) == InUse(apps: ["Google Chrome", "OneDrive"], services: 2))
    }

    @Test func namesAreListedBriefly() {
        #expect(AppModel.list(["Spotify"]) == "Spotify")
        #expect(AppModel.list(["Spotify", "WhatsApp"]) == "Spotify and WhatsApp")
        #expect(AppModel.list(["A", "B", "C"]) == "A, B and C")
        #expect(AppModel.list(["A", "B", "C", "D", "E"]) == "A, B, C and 2 more")
    }

    @Test func emptyTrashReportsWhatsLeftAndWhy() {
        let o = RemovalOutcome(item: FindingItem(path: "trash:", label: "Trash", bytes: 0, lastChange: nil, note: nil,
                                                 preselected: false, removal: .emptyTrash), succeeded: true, message: nil)
        let done = AppModel.emptyReport(o, left: 0, inUse: InUse(), freeNow: 239_000_000_000, freeBefore: 183_000_000_000)
        #expect(done.tone == .done && done.text.hasPrefix("Emptied the Trash."))
        let held = AppModel.emptyReport(o, left: 805_000_000, inUse: InUse(apps: ["Claude", "Spotify"], services: 3),
                                        freeNow: 239_000_000_000, freeBefore: 183_000_000_000)
        #expect(held.tone == .problem)
        #expect(held.text.contains("805 MB is still there: Claude and Spotify are using files in it. Quit them"))
        #expect(held.text.contains("restarting your Mac"))
        let services = AppModel.emptyReport(o, left: 805_000_000, inUse: InUse(apps: [], services: 2),
                                            freeNow: 183_000_000_000, freeBefore: 183_000_000_000)
        #expect(services.text.hasPrefix("805 MB is still in the Trash: macOS services") && services.text.contains("Restart your Mac"))
    }

    /// The Trash is one section of the bar, and what's in it isn't counted again under its kinds.
    @Test func theTrashIsItsOwnSectionOfTheBar() throws {
        let fx = try Fixture()
        try fx.file(".Trash/old video.mov", mb: 3)
        try fx.file("Documents/report.pdf", mb: 2)
        let r = fx.scan()
        let trash = try #require(r.node(at: fx.root + "/.Trash")).allocated
        let model = AppModel()
        model.result = r
        model.trashBytes = trash
        var v = VolumeInfo()
        v.dataUsed = r.root.allocated + 10_000_000
        v.free = 1_000_000_000
        model.volume = v
        let segments = Dictionary(uniqueKeysWithValues: model.diskSegments.map { ($0.id, $0.bytes) })
        #expect(segments["trash"] == trash)
        #expect(segments["kind-\(Kind.media.rawValue)"] == nil)   // the trashed video isn't "Photos, video & music"
        #expect(segments["unseen"] == 10_000_000)
        #expect(segments.filter { $0.key.hasPrefix("kind-") }.values.reduce(0, +) == r.root.allocated - trash)

        // A Home-folder scan sets the Trash apart too, and its bar still adds up to the whole tree.
        model.target = .home
        let home = Dictionary(uniqueKeysWithValues: model.diskSegments.map { ($0.id, $0.bytes) })
        #expect(home["trash"] == trash)
        #expect(home.values.reduce(0, +) == r.root.allocated)

        // A scan of the Trash itself shows what's in it, by kind.
        var o = ScanOptions(root: fx.root + "/.Trash")
        o.home = fx.root
        model.result = Scanner(options: o, progress: ScanProgress()).run()
        model.target = .folder(fx.root + "/.Trash")
        let inside = Dictionary(uniqueKeysWithValues: model.diskSegments.map { ($0.id, $0.bytes) })
        #expect(inside["trash"] == nil)
        #expect(inside["kind-\(Kind.media.rawValue)"] == model.result!.root.kinds[.media])
        #expect(inside.values.reduce(0, +) == model.result!.root.allocated)
    }

    @Test func anUnreadableTrashIsNotAnEmptyOne() throws {
        let fx = try Fixture()
        try fx.file("Trash/locked/video.mov", mb: 2)
        #expect(AppModel.size(of: fx.root + "/Trash").complete)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.root + "/Trash/locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.root + "/Trash/locked") }
        #expect(AppModel.size(of: fx.root + "/Trash").complete == false)
        #expect(AppModel.size(of: fx.root + "/no such folder") == (0, true))
        // A Trash that can't even be looked up, because a folder above it is unreadable, isn't empty.
        try fx.file("locked/Trash/left.bin", mb: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.root + "/locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.root + "/locked") }
        #expect(AppModel.size(of: fx.root + "/locked/Trash").complete == false)

        // What the Trash holds afterwards: a full measurement, else Finder's word, else unchanged.
        #expect(AppModel.trashAfterEmpty(finderSucceeded: true, left: 805) == 805)
        #expect(AppModel.trashAfterEmpty(finderSucceeded: false, left: 0) == 0)
        #expect(AppModel.trashAfterEmpty(finderSucceeded: true, left: nil) == 0)
        #expect(AppModel.trashAfterEmpty(finderSucceeded: false, left: nil) == nil)
    }

    @Test func aFailedEmptyIsAlwaysReported() {
        let item = FindingItem(path: "trash:", label: "Trash", bytes: 0, lastChange: nil, note: nil, preselected: false, removal: .emptyTrash)
        let denied = RemovalOutcome(item: item, succeeded: false,
                                    message: "Silt needs permission to ask Finder. Allow it in System Settings › Privacy & Security › Automation.")
        for left in [nil, 0, 500_000] as [Int64?] {
            let report = AppModel.emptyReport(denied, left: left, inUse: InUse(), freeNow: 1, freeBefore: 1)
            #expect(report.tone == .problem && report.failures.count == 1)
            #expect(report.text.hasPrefix("Finder didn't empty the Trash: Silt needs permission"))
        }
        // Even with apps holding files, Finder's own failure comes first: quitting them won't help.
        let busy = AppModel.emptyReport(denied, left: 157_000_000_000, inUse: InUse(apps: ["ChatGPT", "Claude"], services: 0),
                                        freeNow: 1, freeBefore: 1)
        #expect(busy.text.hasPrefix("Finder didn't empty the Trash: Silt needs permission"))
        #expect(busy.text.contains("157 GB is in it: ChatGPT and Claude are using files in it"))
        let unseen = AppModel.emptyReport(RemovalOutcome(item: item, succeeded: true, message: nil), left: nil, inUse: InUse(),
                                          freeNow: 2_000_000_000, freeBefore: 1_000_000_000)
        #expect(unseen.tone == .note && unseen.text.contains("couldn't look inside the Trash"))
    }
}

@Suite @MainActor struct ClearingTests {
    func item(_ path: String) -> FindingItem {
        FindingItem(path: path, label: path, bytes: 2_000_000, lastChange: nil, note: nil, preselected: true)
    }

    /// The duplicates check lists a copy, the old-files check lists the
    /// same path again without saying what it copies, and both the copy and the original are ticked.
    @Test func overlappingFindingsCantClearBothCopies() {
        let model = AppModel()
        let kept = item("/u/Documents/original.bin")
        var copy = item("/u/Downloads/copy.bin")
        copy.keeps = kept.path
        model.findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy]),
                          Finding(id: "large-unopened", title: "", detail: "", safety: .review, items: [kept, item(copy.path)])]
        model.selected = [kept.path, copy.path]
        model.prepareClear()
        #expect(model.pendingClear.map(\.path) == [kept.path])
        #expect(model.keptDuplicates == 1)
    }

    /// The first clear holds the copy back and takes the original, which
    /// leaves the copy as the last one, so it mustn't stay listed (and ticked) for a second clear.
    @Test func aCopyWhoseOriginalWentIsNoLongerOffered() {
        let kept = item("/u/Documents/a.bin")
        var copy = item("/u/Downloads/a.bin")
        copy.keeps = kept.path
        let findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy]),
                        Finding(id: "large-unopened", title: "", detail: "", safety: .review, items: [kept])]
        let first = FindingItem.sparingLastCopies([kept, copy], sets: FindingItem.duplicateSets(in: findings))
        #expect(first.map(\.path) == [kept.path])
        #expect(Finding.dropping(Set(first.map(\.path)), from: findings).isEmpty)
        #expect(Finding.dropping(["/u/Documents"], from: findings).isEmpty)
        #expect(Finding.dropping(["/u/Elsewhere"], from: findings).count == 2)
    }

    /// The copy is listed twice, and the first clear holds it back
    /// while taking the original. Its other listing mustn't leave it ticked for a second clear.
    @Test func aCopyListedTwiceStaysSafeOnTheNextClear() {
        let model = AppModel()
        let kept = item("/u/Documents/original.bin")
        var copy = item("/u/Downloads/copy.bin")
        copy.keeps = kept.path
        model.findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy]),
                          Finding(id: "large-unopened", title: "", detail: "", safety: .review, items: [kept, item(copy.path)])]
        model.selected = [kept.path, copy.path]
        model.prepareClear()
        #expect(model.pendingClear.map(\.path) == [kept.path])
        model.clearSelected()   // no scan, so nothing is performed; this unticks what was held back
        model.forget([kept.path])
        #expect(model.findings.isEmpty && model.selected.isEmpty)
        model.selected = [copy.path]   // even ticked again by hand…
        model.prepareClear()
        #expect(model.pendingClear.isEmpty)   // …it's the last copy now
    }

    /// The other way round: the first clear takes a folder holding the copy and holds the
    /// original back, so the original mustn't stay offered (or ticked) for the next one.
    @Test func anOriginalHeldBackForAFolderStaysSafeOnTheNextClear() {
        let model = AppModel()
        let kept = item("/u/Documents/original.bin")
        var copy = item("/u/Downloads/old stuff/copy.bin")
        copy.keeps = kept.path
        model.findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy]),
                          Finding(id: "old-downloads", title: "", detail: "", safety: .review, items: [item("/u/Downloads/old stuff")]),
                          Finding(id: "large-unopened", title: "", detail: "", safety: .review, items: [kept])]
        model.selected = ["/u/Downloads/old stuff", kept.path]
        model.prepareClear()
        #expect(model.pendingClear.map(\.path) == ["/u/Downloads/old stuff"])
        model.clearSelected()
        #expect(!model.selected.contains(kept.path))
        model.forget(["/u/Downloads/old stuff"])
        #expect(model.findings.isEmpty)
    }

    /// A folder that holds the last copy is held back on a later clear, though no row about
    /// the copies is left by then.
    @Test func protectionOutlivesTheRows() {
        let model = AppModel()
        let kept = item("/u/Projects/old/original.bin")
        var copy = item("/u/Downloads/copy.bin")
        copy.keeps = kept.path
        model.findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy]),
                          Finding(id: "untouched", title: "", detail: "", safety: .review, items: [item("/u/Projects/old")])]
        model.selected = [copy.path]
        model.prepareClear()
        #expect(model.pendingClear.map(\.path) == [copy.path])
        model.clearSelected()
        model.forget([copy.path])
        #expect(model.findings.map(\.id) == ["untouched"])
        model.selected = ["/u/Projects/old"]
        model.prepareClear()
        #expect(model.pendingClear.isEmpty && model.keptDuplicates == 1)
        // With nothing left to confirm there's no dialog, so Silt says why and unticks it.
        #expect(!model.askToClear && model.selected.isEmpty)
        #expect(model.report?.text.hasPrefix("Nothing cleared: the ticked item holds the last copy") == true)
    }

    @Test func movingTheLastCopyByHandSaysSo() throws {
        let fx = try Fixture()
        let kept = try fx.file("Documents/a.bin", mb: 2)
        let copyPath = try fx.file("Downloads/a.bin", mb: 2)
        let model = AppModel()
        let r = fx.scan()
        model.result = r
        var copy = item(copyPath)
        copy.keeps = kept
        model.findings = [Finding(id: "duplicates", title: "", detail: "", safety: .review, items: [copy])]
        let original = try #require(r.node(at: kept))

        model.confirmSingle(original)
        #expect(model.single?.path == kept && !model.singleIsLastCopy)   // the copy is still there
        model.confirmSingle(r.root)
        #expect(model.singleIsLastCopy)                                  // a folder holding both copies
        model.forget([copyPath])
        model.confirmSingle(original)
        #expect(model.singleIsLastCopy)                                  // the copy went in an earlier clear
    }

    @Test func noRescanWhileAClearIsRunning() {
        let model = AppModel()
        model.working = "Moving 1 item to the Trash…"
        model.scan(.home)
        #expect(model.target == .wholeDisk && !model.scanning)
    }

    @Test func nothingClearsWhileACheckIsReadingTheTree() {
        let model = AppModel()
        model.findings = [Finding(id: "logs", title: "", detail: "", safety: .rebuildable, items: [item("/u/Library/Logs/x")])]
        model.selected = ["/u/Library/Logs/x"]
        model.checksRunning = ["duplicates"]
        #expect(model.treeInUse)
        model.prepareClear()
        #expect(!model.askToClear && model.pendingClear.isEmpty)
        model.checksRunning = []
        model.prepareClear()
        #expect(model.askToClear && model.pendingClear.count == 1)
    }
}

@Suite struct RulesTests {
    @Test func derivedDataNamesAndAerialsKeepTheOneInUse() throws {
        let fx = try Fixture()
        try fx.file("Library/Developer/Xcode/DerivedData/Silt-abcdefghijklmnopqrstuvwxyzab/Build/x.o", mb: 2)
        let wall = "Library/Application Support/com.apple.wallpaper"
        try fx.file("\(wall)/aerials/videos/AAAA-1.mov", mb: 2)
        try fx.file("\(wall)/aerials/videos/BBBB-2.mov", mb: 2)
        let inner = try PropertyListSerialization.data(fromPropertyList: ["assetID": "BBBB-2"], format: .binary, options: 0)
        let index: [String: Any] = ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Configuration": inner]]]]]]
        try fx.dir("\(wall)/Store")
        try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: fx.root + "/\(wall)/Store/Index.plist"))

        let findings = Rules.immediate(fx.scan())
        #expect(findings.first { $0.id == "xcode-derived-data" }?.items.first?.label == "Silt")
        let aerials = try #require(findings.first { $0.id == "aerials" })
        #expect(aerials.items.map(\.path) == [fx.root + "/\(wall)/aerials/videos/AAAA-1.mov"])
        #expect(aerials.detail.hasSuffix("The one you're using is kept."))

        // The store can name an aerial that was never downloaded; then nothing was kept, and Silt mustn't say so.
        try FileManager.default.removeItem(atPath: fx.root + "/\(wall)/aerials/videos/BBBB-2.mov")
        let again = try #require(Rules.immediate(fx.scan()).first { $0.id == "aerials" })
        #expect(again.items.count == 1)
        #expect(!again.detail.contains("is kept"))
    }

    @Test func onlyInstallersAreTickedNotISOs() throws {
        let fx = try Fixture()
        try fx.file("Downloads/Tool.pkg", mb: 2)
        try fx.file("Downloads/linux.iso", mb: 2)
        // Both just arrived, so look from two months on.
        let later = Date().addingTimeInterval(60 * 86_400)
        let installers = try #require(Rules.immediate(fx.scan(), now: later).first { $0.id == "installers" })
        let ticked = Dictionary(uniqueKeysWithValues: installers.items.map { (($0.path as NSString).lastPathComponent, $0.preselected) })
        #expect(ticked == ["Tool.pkg": true, "linux.iso": false])
    }

    @Test func androidImagesInUseAreKept() throws {
        let fx = try Fixture()
        try fx.file("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/system.img", mb: 2)
        try fx.file("Library/Android/sdk/system-images/android-29/google_apis/arm64-v8a/system.img", mb: 2)
        try fx.file(".android/avd/Pixel.avd/config.ini")
        try "image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\n"
            .write(toFile: fx.root + "/.android/avd/Pixel.avd/config.ini", atomically: true, encoding: .utf8)
        let images = try #require(Rules.immediate(fx.scan()).first { $0.id == "android-images" })
        #expect(images.items.map(\.label) == ["android-29 · google_apis"])
    }

    @Test func dockerSizes() {
        #expect(Rules.parseDockerSize("5.296GB (74%)") == 5_296_000_000)
        #expect(Rules.parseDockerSize("449kB (49%)") == 449_000)
        #expect(Rules.parseDockerSize("0B") == 0)
    }
}

// MARK: - Safety

@Suite struct SafetyTests {
    let home = "/Users/someone"
    var g: SafetyGuard { SafetyGuard(home: home, appBundle: "/Applications/Silt.app") }

    @Test func refusesTheThingsThatMustStay() {
        for p in ["/", "/Users", home, home + "/Library", home + "/Documents", home + "/Desktop", home + "/Downloads",
                  home + "/Library/Caches", "/Applications", "/System/Library", "/usr/local/bin/x", home + "/.ssh/id_ed25519",
                  home + "/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", "/Applications/Silt.app",
                  home + "/Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
                  home + "/Applications/Thing.app/Contents/MacOS/Thing", "/Library/Caches/x", "/private/var/folders/x/y/z"] {
            #expect(g.refusal(for: p) != nil, "should refuse \(p)")
        }
    }

    @Test func refusesNonCanonicalPaths() {
        for p in [home + "/Downloads/../Documents/x", home + "/./Library", home + "/Downloads/x/", "relative/path", home + "//Library"] {
            #expect(g.refusal(for: p) != nil, "should refuse \(p)")
        }
    }

    @Test func allowsOrdinaryCandidates() throws {
        let fx = try Fixture()
        let guardHere = SafetyGuard(home: fx.root, appBundle: "/Applications/Silt.app")
        let path = try fx.file("Library/Caches/com.example.app/blob", mb: 0.1)
        #expect(guardHere.refusal(for: path) == nil)
        #expect(guardHere.refusal(for: fx.root + "/Library/Caches/gone") != nil)   // doesn't exist
        let inApp = try fx.file("Applications/Real.app/Contents/Resources/big.bin", mb: 0.1)
        #expect(guardHere.refusal(for: inApp) != nil)
    }

    @Test func symlinksAreJudgedByWhereTheyLead() throws {
        let fx = try Fixture()
        try fx.file("Library/Mobile Documents/com~apple~CloudDocs/proj/node_modules/x.js", mb: 0.1)
        try FileManager.default.createSymbolicLink(atPath: fx.root + "/proj",
                                                   withDestinationPath: fx.root + "/Library/Mobile Documents/com~apple~CloudDocs/proj")
        let g = SafetyGuard(home: fx.root, appBundle: "/Applications/Silt.app")
        #expect(g.refusal(for: fx.root + "/proj/node_modules") != nil)
        #expect(g.refusal(for: fx.root + "/proj") == nil)   // the link itself can go; the Trash takes the link
    }

    @Test func appContainersOnlyGiveUpTheirCaches() throws {
        let fx = try Fixture()
        let caches = try fx.file("Library/Containers/com.example.app/Data/Library/Caches/blob", mb: 0.1)
        let data = try fx.file("Library/Containers/com.example.app/Data/Documents/novel.txt", mb: 0.1)
        let backup = try fx.file("Library/Application Support/MobileSync/Backup/AAAA/00/file", mb: 0.1)
        let notes = try fx.file("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", mb: 0.1)
        let g = SafetyGuard(home: fx.root, appBundle: "/Applications/Silt.app")
        #expect(g.refusal(for: caches) == nil)
        #expect(g.refusal(for: data) != nil)
        #expect(g.refusal(for: backup) != nil)
        #expect(g.refusal(for: fx.root + "/Library/Application Support/MobileSync/Backup/AAAA") == nil)
        #expect(g.refusal(for: notes) != nil)
    }

    @Test func trashingReallyMovesToTrash() throws {
        let fx = try Fixture()
        let path = try fx.file("Library/Caches/com.example.app/blob", mb: 0.1)
        let item = FindingItem(path: path, label: "blob", bytes: 1, lastChange: nil, note: nil, preselected: true)
        let outcome = Remover.perform(item, guard: SafetyGuard(home: fx.root, appBundle: "/Applications/Silt.app"))
        #expect(outcome.succeeded)
        #expect(!FileManager.default.fileExists(atPath: path))
        let trashed = try #require(outcome.trashedTo)
        #expect(trashed.path.contains("/.Trash"))
        // Take it straight back out so the test leaves nothing behind.
        try? FileManager.default.removeItem(at: trashed)
    }

    @Test func refusedItemsAreNotTouched() throws {
        let fx = try Fixture()
        try fx.file("Documents/keep.txt", mb: 0.1)
        let item = FindingItem(path: fx.root + "/Documents", label: "Documents", bytes: 1, lastChange: nil, note: nil, preselected: true)
        let outcome = Remover.perform(item, guard: SafetyGuard(home: fx.root, appBundle: "/Applications/Silt.app"))
        #expect(!outcome.succeeded)
        #expect(FileManager.default.fileExists(atPath: fx.root + "/Documents/keep.txt"))
    }
}

// MARK: - Paths and formatting

@Suite struct PathTests {
    @Test func firmlinksMapToFamiliarPaths() {
        let m = PathMap(ioRoot: PathMap.dataVolume)
        #expect(m.path(forRelative: "Users/you/Library") == "/Users/you/Library")
        #expect(m.path(forRelative: "usr/local/bin") == "/usr/local/bin")
        #expect(m.path(forRelative: ".Spotlight-V100") == "/System/Volumes/Data/.Spotlight-V100")
        #expect(m.relative(forPath: "/Users/you") == "Users/you")
        #expect(m.relative(forPath: "/System/Volumes/Data/.fseventsd") == ".fseventsd")
        #expect(m.relative(forPath: "/bin/ls") == nil)   // on the sealed system volume
    }

    @Test func bytesAndAges() {
        #expect(Format.bytes(21_800_000_000) == "21.8 GB")
        #expect(Format.bytes(145_000_000_000) == "145 GB")
        #expect(Format.bytes(999_000) == "999 KB")
        let now = Date()
        #expect(Format.age(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
        #expect(Format.age(now.addingTimeInterval(-800 * 86_400), now: now) == "2 years ago")
    }
}
