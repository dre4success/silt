import SiltCore
import SwiftUI

/// One column, read top to bottom: the headline, what can go, where the space went, and how
/// old it is. Nothing is tucked away in tabs.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let s = Theme.scale(forWidth: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 52 * s) {
                    HeaderSection()
                    if model.target == .wholeDisk && !model.hasFullDiskAccess && model.result != nil { AccessNote() }
                    FindingsSection()
                    MapSection()
                    StrataSection()
                    Footer()
                }
                .frame(maxWidth: 1040 * s, alignment: .leading)
                .padding(.horizontal, 36 * s)
                .padding(.top, 24 * s)
                .padding(.bottom, 36 * s)
                .frame(maxWidth: .infinity)
                .background(Palette.page)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ActionBar() }
            .environment(\.uiScale, s)
        }
        .background(Palette.page)
        .navigationTitle("Silt")
        .navigationSubtitle(model.scanning ? "Scanning \(model.target.title.lowercased())…" : model.target.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Whole disk") { model.scan(.wholeDisk) }
                    Button("Home folder") { model.scan(.home) }
                    Divider()
                    Button("Choose a Folder…") { model.chooseFolder() }
                } label: {
                    Label(model.target.title, systemImage: "internaldrive")
                }
                .help("What to scan")
                .disabled(model.working != nil)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.scanning {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .help("Scan again (⌘R)")
                        .disabled(model.working != nil)
                }
            }
        }
        .confirmationDialog(clearTitle, isPresented: $model.askToClear, titleVisibility: .visible) {
            Button(clearTitle) { model.clearSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearMessage)
        }
        .confirmationDialog("Empty the Trash?", isPresented: $model.askToEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes everything in the Trash, including things you put there yourself, and frees about \(Format.bytes(model.trashBytes)).")
        }
        .confirmationDialog(singleTitle, isPresented: Binding(get: { model.single != nil }, set: { if !$0 { model.single = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash") { if let i = model.single { model.perform([i]) }; model.single = nil }
            Button("Cancel", role: .cancel) { model.single = nil }
        } message: {
            Text("\(model.single?.label ?? "") takes \(Format.bytes(model.single?.bytes ?? 0)). You can put it back from the Trash until you empty it."
                 + (model.singleIsLastCopy ? "\n\nThis would put every copy of a file Silt found duplicated in the Trash." : ""))
        }
    }

    private var clearTitle: String { "Clear \(Format.bytes(model.pendingClear.reduce(0) { $0 + $1.bytes }))?" }

    private var singleTitle: String {
        "Move “\(((model.single?.path ?? "") as NSString).lastPathComponent)” to the Trash?"
    }

    private var clearMessage: String {
        let items = model.pendingClear
        let trash = items.filter { $0.removal == .trash }
        let commands = items.compactMap { item -> KnownCommand? in
            if case .command(let c) = item.removal { return c } else { return nil }
        }
        var lines: [String] = []
        if !trash.isEmpty {
            lines.append("\(trash.count) item\(trash.count == 1 ? "" : "s") (\(Format.bytes(trash.reduce(0) { $0 + $1.bytes }))) go to the Trash. You can put any of them back until you empty it.")
        }
        if !commands.isEmpty {
            lines.append("Silt will also run:\n" + commands.map { "  \($0.display)" }.joined(separator: "\n")
                         + "\nThese delete for good, but only things that download or rebuild again.")
        }
        let inUse = model.pendingInUse
        if !inUse.apps.isEmpty {
            let one = inUse.apps.count == 1
            lines.append("\(AppModel.list(inUse.apps)) \(one ? "is" : "are") using some of these. Quit \(one ? "it" : "them") first: Finder can't delete files in use, so the Trash won't empty fully while \(one ? "it runs" : "they run").")
        }
        if inUse.services > 0 {
            lines.append("Some macOS services are using a few of these files. If the Trash doesn't empty fully afterwards, restart your Mac and empty it again.")
        }
        if model.keptDuplicates > 0 {
            lines.append("\(model.keptDuplicates) ticked item\(model.keptDuplicates == 1 ? " stays" : "s stay"), so that one copy of every duplicated file is kept.")
        }
        return lines.joined(separator: "\n\n")
    }
}

struct Footer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = model.result {
                Text("Scanned \(r.map.isWholeDisk ? "the whole disk" : r.display(r.rootPath)) in \(String(format: "%.1f", r.seconds)) s: \(Format.count(r.files)) files in \(Format.count(r.folders)) folders. Sizes are the space on disk; \"frees\" is what APFS would actually hand back, which is less where files are clones of each other.")
            }
            Text("Silt only reads your disk until you press Clear. Nothing is removed without that, and files only ever go to the Trash.")
        }
        .siltFont(12.5)
        .foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Always on screen at the bottom: what's ticked, and the one button that acts on it.
struct ActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s

    var body: some View {
        let items = model.selectedItems
        HStack(spacing: 16 * s) {
            if let working = model.working {
                ProgressView().controlSize(.small)
                Text(working).siltFont(13.5).foregroundStyle(Palette.ink2)
            } else if let report = model.report {
                Image(systemName: report.tone == .problem || !report.failures.isEmpty ? "exclamationmark.triangle"
                                  : report.tone == .note ? "info.circle" : "checkmark.circle")
                    .foregroundStyle(Palette.ink2)
                Text(report.text).siltFont(13.5).foregroundStyle(Palette.ink2).lineLimit(3)
                    .help(([report.text] + report.failures.map { "\($0.item.label): \($0.message ?? "")" }).joined(separator: "\n"))
            }
            Spacer(minLength: 12)
            if model.trashBytes > 0 {
                Button("Empty Trash (\(Format.bytes(model.trashBytes)))…") { model.askToEmptyTrash = true }
                    .disabled(model.treeInUse)
            }
            Text(items.isEmpty ? "Nothing ticked" : "\(items.count) ticked")
                .siltFont(13.5).monospacedDigit().foregroundStyle(Palette.ink2)
            Button {
                model.requestClear()
            } label: {
                Text(items.isEmpty ? "Clear" : "Clear \(Format.bytes(model.selectedBytes))…")
                    .siltFont(14, .semibold)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(items.isEmpty || model.treeInUse)
            .help(model.checksRunning.isEmpty ? "" : "Clear waits until Silt has finished checking.")
        }
        .padding(.horizontal, 24 * s)
        .padding(.vertical, 12 * s)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}
