import AppKit
import SiltCore
import SwiftUI

@main
struct SiltApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // See the note in FindingsSection about `State(initialValue:)`.
    private let modelState = State(initialValue: AppModel())
    private var model: AppModel { modelState.wrappedValue }

    init() {
        // For snapshots: force an appearance before any window exists.
        if let mode = ProcessInfo.processInfo.environment["SILT_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
    }

    var body: some Scene {
        Window("Silt", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 600)
                .task {
                    Snapshot.armIfRequested(model)
                    model.start()
                }
        }
        .defaultSize(width: 1180, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Rescan") { model.scan() }.keyboardShortcut("r").disabled(model.working != nil)
                Button("Scan a Folder…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.working != nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Matters when the binary is run directly rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `SILT_SNAPSHOT=/path/out.png` makes the app scan, wait for every check to finish, draw
/// the whole page into a PNG and quit. It's how the layout gets checked without a person
/// clicking through it.
@MainActor
enum Snapshot {
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView != nil { return s }
        for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
        return nil
    }

    static func armIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SILT_SNAPSHOT"] else { return }
        let height = CGFloat(Double(env["SILT_SNAPSHOT_HEIGHT"] ?? "") ?? 4200)
        let width = CGFloat(Double(env["SILT_SNAPSHOT_WIDTH"] ?? "") ?? 1180)
        model.onSettled = {
            if let expand = env["SILT_EXPAND"] { model.expanded.insert(expand) }
            if env["SILT_COLOR"] == "age" { model.colorMode = .age }
            if let f = env["SILT_FOCUS"], let r = model.result, let n = r.node(at: (f as NSString).expandingTildeInPath) { model.focus = n }
            if env["SILT_AUTOCLEAR"] == "1" && AppModel.isHarness {
                model.prepareClear()
                model.clearSelected()
                Task {
                    while model.working != nil { try? await Task.sleep(for: .milliseconds(100)) }
                    for url in model.report?.trashed ?? [] { print("TRASHED \(url.path)") }
                    for f in model.report?.failures ?? [] { print("FAILED \(f.item.path): \(f.message ?? "")") }
                    print("REPORT \(model.report?.text ?? "none")")
                    capture(env: env, out: out, width: width, height: height)
                }
                return
            }
            capture(env: env, out: out, width: width, height: height)
        }
    }

    static func capture(env: [String: String], out: String, width: CGFloat, height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { exit(2) }
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // The window can't be taller than the screen, so draw the scroll view's whole
            // document instead of what's on screen.
            guard let content = window.contentView else { exit(2) }
            let target = scrollView(in: content)?.documentView ?? content
            guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { exit(2) }
            target.cacheDisplay(in: target.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}
