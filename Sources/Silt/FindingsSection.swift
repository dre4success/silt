import SiltCore
import SwiftUI

/// The list of what can go, biggest first, in two groups: things that rebuild themselves,
/// and things that are yours and need a look.
struct FindingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * s) {
            SectionHeading(title: "Clear space",
                           detail: "Ticked items go to the Trash, so anything can be put back until you empty it. A few caches are cleared by their own tool instead; the confirmation names them.")
            if model.result == nil {
                Placeholder(text: model.scanning ? "What you can clear appears as soon as the scan finishes." : "Scan to see what you can clear.")
            } else {
                group("Rebuilds itself", symbol: "arrow.triangle.2.circlepath",
                      blurb: "Caches, downloads and build output that come back by themselves when needed.",
                      model.rebuildable)
                group("Check first", symbol: "eye",
                      blurb: "Your own things that look unused. Silt can't know you don't want them.",
                      model.review)
                if !model.checksRunning.isEmpty {
                    HStack(spacing: 10 * s) {
                        ProgressView().controlSize(.small)
                        Text("Still checking \(model.checksRunning.joined(separator: ", "))…")
                            .siltFont(13.5).foregroundStyle(Palette.ink2)
                    }
                } else if model.findings.isEmpty {
                    Placeholder(text: "Nothing obvious to clear here. The map below shows where the space went.")
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, symbol: String, blurb: String, _ findings: [Finding]) -> some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 12 * s) {
                HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                    Image(systemName: symbol).siltFont(15, .semibold).foregroundStyle(Palette.ink2)
                    Text(title).siltFont(17, .semibold).foregroundStyle(Palette.ink)
                    Text(Format.bytes(model.uniqueBytes(findings))).siltFont(17).monospacedDigit().foregroundStyle(Palette.ink2)
                }
                Text(blurb).siltFont(13.5).foregroundStyle(Palette.ink2)
                ForEach(findings) { FindingCard(finding: $0) }
            }
            .padding(.top, 6 * s)
        }
    }
}

struct FindingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s
    let finding: Finding

    private let shown = 5

    var body: some View {
        let isOpen = model.expanded.contains(finding.id)
        let items = isOpen ? finding.items : Array(finding.items.prefix(shown))
        let ticked = finding.items.filter { model.isSelected($0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14 * s) {
                CheckBox(state: model.state(of: finding)) { model.toggleAll(finding) }
                    .padding(.top, 2 * s)
                Text(Format.bytes(finding.bytes))
                    .siltFont(20, .semibold).monospacedDigit().foregroundStyle(Palette.ink)
                    .frame(minWidth: 92 * s, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4 * s) {
                    Text(finding.title).siltFont(16, .semibold).foregroundStyle(Palette.ink)
                    Text(finding.detail).siltFont(13.5).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8 * s)
                Text(ticked.isEmpty ? "none ticked" : ticked.count == finding.items.count ? "all ticked" : "\(ticked.count) of \(finding.items.count) ticked")
                    .siltFont(12.5).foregroundStyle(Palette.muted)
                    .padding(.top, 4 * s)
            }
            .padding(.horizontal, 16 * s)
            .padding(.vertical, 14 * s)

            Rectangle().fill(Palette.hairline).frame(height: 1)

            VStack(spacing: 0) {
                ForEach(items) { ItemRow(item: $0) }
            }
            .padding(.vertical, 4 * s)

            if finding.items.count > shown {
                let rest = finding.items.dropFirst(shown)
                Button {
                    if isOpen { model.expanded.remove(finding.id) } else { model.expanded.insert(finding.id) }
                } label: {
                    Text(isOpen ? "Show fewer" : "Show \(rest.count) more · \(Format.bytes(rest.reduce(0) { $0 + $1.bytes }))")
                        .siltFont(13, .medium)
                }
                .buttonStyle(.link)
                .padding(.horizontal, 16 * s)
                .padding(.bottom, 12 * s)
                .padding(.leading, 36 * s)
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s
    let item: FindingItem
    // `State(initialValue:)` rather than `@State`: in this SDK `@State` is a macro whose plugin
    // ships only with Xcode. SwiftUI still finds the stored `State` and manages it the same way.
    private let hoverState = State(initialValue: false)
    private var hovering: Bool { hoverState.wrappedValue }

    var body: some View {
        HStack(spacing: 12 * s) {
            CheckBox(state: model.isSelected(item) ? .on : .off) { model.toggle(item) }
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(item.label).siltFont(13.5, .medium).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let note = item.note {
                    Text(note).siltFont(12).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8 * s)
            if let date = item.lastChange, item.note == nil {
                Text(Format.age(date)).siltFont(12.5).foregroundStyle(Palette.muted)
            }
            Text(Format.bytes(item.bytes)).siltFont(13.5).monospacedDigit().foregroundStyle(Palette.ink2)
                .frame(minWidth: 70 * s, alignment: .trailing)
            Button { model.reveal(item.path) } label: {
                Image(systemName: "magnifyingglass").siltFont(12.5)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .opacity(item.isFile ? (hovering ? 1 : 0.35) : 0)
            .disabled(!item.isFile)
        }
        .padding(.leading, 16 * s)
        .padding(.trailing, 14 * s)
        .padding(.vertical, 6 * s)
        .background(hovering ? Palette.hairline.opacity(0.45) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item) }
        .onHover { hoverState.wrappedValue = $0 }
        .help(item.path.hasPrefix("command:") ? item.note ?? "" : item.path)
    }
}
