import SiltCore
import SwiftUI

/// The whole tree as a treemap you can walk into, with a plain sorted list underneath.
struct MapSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14 * s) {
            SectionHeading(title: "Where it went",
                           detail: "Each block is a folder or file, sized by the space it takes. Click one to look inside; right-click for Finder or the Trash.")
            if let r = model.result, let focus = model.focus {
                HStack(alignment: .center) {
                    Breadcrumb(result: r, focus: focus)
                    Spacer(minLength: 12)
                    Text("Colour by").siltFont(12.5).foregroundStyle(Palette.muted)
                    Picker("Colour by", selection: $model.colorMode) {
                        ForEach(ColorMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                TreemapView(result: r, focus: focus, mode: model.colorMode, hovered: model.hovered, revision: model.revision)
                    .frame(height: 540 * s)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                HoverLine(result: r, node: model.hovered ?? focus, mode: model.colorMode, revision: model.revision)
                if model.colorMode == .age { AgeKey() } else { KindKey() }
                ChildList(result: r, focus: focus, revision: model.revision)
            } else {
                Placeholder(text: "The map draws itself when the scan finishes.")
            }
        }
    }
}

struct Breadcrumb: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult
    let focus: Node

    var body: some View {
        var chain: [Node] = []
        var n: Node? = focus
        while let cur = n { chain.insert(cur, at: 0); n = cur.parent }
        // Long paths keep their start and their last few steps.
        let shown: [Node?] = chain.count > 6 ? [chain[0], nil] + chain.suffix(4) : chain
        return HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, node in
                if i > 0 { Image(systemName: "chevron.right").siltFont(10, .semibold).foregroundStyle(Palette.muted) }
                if let node {
                    Button(node.parent == nil ? result.display(result.rootPath) == "/" ? node.name : result.display(result.rootPath) : node.name) {
                        model.focus = node
                    }
                    .buttonStyle(.plain)
                    .siltFont(13.5, node === focus ? .semibold : .regular)
                    .foregroundStyle(node === focus ? Palette.ink : Color.accentColor)
                    .lineLimit(1)
                } else {
                    Text("…").siltFont(13.5).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}

// MARK: - Treemap

struct Tile {
    let node: Node?
    let rect: CGRect
    let level: Int
    let container: Bool
    let header: CGFloat
    let bytes: Int64
    let owner: Node   // the folder this tile belongs to, so "smaller items" can zoom somewhere
    var title: String? = nil
}

/// Layout is recomputed only when the folder, the size or the tree changes, not on every hover.
@MainActor final class TileCache {
    private var key: (ObjectIdentifier, CGSize, Int)?
    private(set) var tiles: [Tile] = []

    func tiles(for focus: Node, size: CGSize, revision: Int) -> [Tile] {
        if let k = key, k.0 == ObjectIdentifier(focus), k.1 == size, k.2 == revision { return tiles }
        key = (ObjectIdentifier(focus), size, revision)
        tiles = Self.layout(focus, in: CGRect(origin: .zero, size: size))
        return tiles
    }

    static func entries(_ n: Node, limit: Int) -> [(node: Node?, bytes: Int64)] {
        var out: [(node: Node?, bytes: Int64)] = []
        var rest = n.otherBytes
        for (i, c) in n.children.enumerated() {
            if i < limit && c.allocated > 0 { out.append((c, c.allocated)) } else { rest += max(0, c.allocated) }
        }
        if rest > 0 { out.append((nil, rest)) }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// A folder that is almost all one subfolder (`/Users` is just your home) is drawn as that
    /// subfolder, so the map shows what's inside instead of one big block.
    static func collapse(_ n: Node) -> (shown: Node, title: String) {
        var cur = n
        var names = [n.name]
        while let big = cur.children.first, big.isDirectory, !big.children.isEmpty, big.allocated >= cur.allocated * 9 / 10 {
            cur = big
            names.append(big.name)
        }
        return (cur, names.joined(separator: " › "))
    }

    /// Two levels: the folder's children, and inside each big enough child, its children.
    static func layout(_ focus: Node, in bounds: CGRect) -> [Tile] {
        var tiles: [Tile] = []
        let top = entries(focus, limit: 60)
        let rects = Treemap.squarify(top.map { Double($0.bytes) }, in: bounds)
        for (e, r) in zip(top, rects) where r.width >= 1 && r.height >= 1 {
            if let outer = e.node, outer.isDirectory, !outer.children.isEmpty, r.width > 56, r.height > 48 {
                let (n, title) = collapse(outer)
                let header: CGFloat = r.height > 72 && r.width > 96 ? 20 : 0
                tiles.append(Tile(node: n, rect: r, level: 1, container: true, header: header, bytes: e.bytes, owner: focus, title: title))
                let inner = CGRect(x: r.minX + 3, y: r.minY + (header > 0 ? header : 3),
                                   width: r.width - 6, height: r.height - (header > 0 ? header + 3 : 6))
                let sub = entries(n, limit: 40)
                for (se, sr) in zip(sub, Treemap.squarify(sub.map { Double($0.bytes) }, in: inner)) where sr.width >= 1 && sr.height >= 1 {
                    tiles.append(Tile(node: se.node, rect: sr, level: 2, container: false, header: 0, bytes: se.bytes, owner: n))
                }
            } else {
                tiles.append(Tile(node: e.node, rect: r, level: 1, container: false, header: 0, bytes: e.bytes, owner: focus))
            }
        }
        return tiles
    }
}

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s
    let result: ScanResult
    let focus: Node
    let mode: ColorMode
    let hovered: Node?
    let revision: Int
    // `State(initialValue:)` rather than `@State`: in this SDK `@State` is a macro whose plugin
    // ships only with Xcode. SwiftUI still finds the stored `State` and manages it the same way.
    private let cacheState = State(initialValue: TileCache())
    private let hoverState = State<Int?>(initialValue: nil)
    private var cache: TileCache { cacheState.wrappedValue }
    private var hoverTile: Int? {
        get { hoverState.wrappedValue }
        nonmutating set { hoverState.wrappedValue = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(for: focus, size: geo.size, revision: revision)
            let hot = hoverTile
            Canvas { ctx, _ in
                for (i, t) in tiles.enumerated() { draw(t, highlighted: i == hot, in: &ctx) }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let i = hit(tiles, p)
                    if i != hoverTile {
                        hoverTile = i
                        model.hovered = i.flatMap { tiles[$0].node }
                    }
                case .ended:
                    hoverTile = nil
                    model.hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                guard let i = hit(tiles, p) else { return }
                let t = tiles[i]
                if let n = t.node, n.isDirectory, !n.children.isEmpty {
                    model.focus = n
                } else if t.owner !== focus {
                    model.focus = t.owner
                }
                hoverTile = nil
            }
            .contextMenu { NodeMenu(node: hovered) }
        }
    }

    private func hit(_ tiles: [Tile], _ p: CGPoint) -> Int? {
        tiles.indices.reversed().first { tiles[$0].rect.contains(p) }
    }

    private func fill(_ n: Node?) -> Color {
        guard let n else { return Palette.smaller }
        return mode == .kind ? Palette.kind(n.kind) : Palette.age(Palette.ageFraction(days: n.meanAgeDays))
    }

    private func ink(on n: Node?) -> Color {
        guard let n else { return Palette.ink2 }
        return mode == .kind ? Palette.label(onKind: n.kind) : Palette.label(onAge: Palette.ageFraction(days: n.meanAgeDays))
    }

    private func draw(_ t: Tile, highlighted: Bool, in ctx: inout GraphicsContext) {
        // A 1px inset on every side leaves a 2px gap between neighbours, in the surface colour.
        let r = t.rect.insetBy(dx: 1, dy: 1)
        guard r.width > 0.5, r.height > 0.5 else { return }
        let shape = Path(roundedRect: r, cornerRadius: min(4, r.width / 3, r.height / 3))
        if t.container {
            ctx.fill(shape, with: .color(fill(t.node).opacity(0.16)))
            if t.header > 0 {
                label(name: t.title ?? t.node?.name ?? "", bytes: t.bytes, in: CGRect(x: r.minX + 6, y: r.minY + 2, width: r.width - 12, height: t.header - 2),
                      color: Palette.ink, oneLine: true, ctx: &ctx)
            }
        } else {
            ctx.fill(shape, with: .color(fill(t.node)))
            if r.width > 60 && r.height > 30 {
                label(name: t.node?.name ?? "Smaller items", bytes: t.bytes,
                      in: CGRect(x: r.minX + 6, y: r.minY + 4, width: r.width - 12, height: r.height - 8),
                      color: ink(on: t.node), oneLine: false, ctx: &ctx)
            }
        }
        if highlighted {
            ctx.stroke(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4), with: .color(Palette.ink), lineWidth: 2)
        }
    }

    /// Labels are measured and shortened with an ellipsis to fit; a tile too small for its
    /// label simply has none, and the hover line below carries it instead.
    private func label(name: String, bytes: Int64, in box: CGRect, color: Color, oneLine: Bool, ctx: inout GraphicsContext) {
        let size = Format.bytes(bytes)
        let nameFont = Font.system(size: 11.5 * s, weight: .semibold)
        let sizeFont = Font.system(size: 11 * s)
        func resolved(_ s: String, _ f: Font) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(f).foregroundStyle(color))
        }
        let boxSize = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        if oneLine {
            let sizeText = resolved(size, sizeFont)
            let sw = sizeText.measure(in: boxSize).width
            guard let fitted = fit(name, width: box.width - sw - 8, font: nameFont, ctx: ctx, color: color) else { return }
            ctx.draw(resolved(fitted, nameFont), at: CGPoint(x: box.minX, y: box.midY), anchor: .leading)
            if sw < box.width { ctx.draw(sizeText, at: CGPoint(x: box.maxX, y: box.midY), anchor: .trailing) }
        } else {
            guard let fitted = fit(name, width: box.width, font: nameFont, ctx: ctx, color: color) else { return }
            let nameText = resolved(fitted, nameFont)
            let h = nameText.measure(in: boxSize).height
            ctx.draw(nameText, at: CGPoint(x: box.minX, y: box.minY), anchor: .topLeading)
            let sizeText = resolved(size, sizeFont)
            let m = sizeText.measure(in: boxSize)
            if h + m.height + 2 <= box.height && m.width <= box.width {
                ctx.draw(sizeText, at: CGPoint(x: box.minX, y: box.minY + h + 1), anchor: .topLeading)
            }
        }
    }

    private func fit(_ text: String, width: CGFloat, font: Font, ctx: GraphicsContext, color: Color) -> String? {
        guard width > 20 else { return nil }
        func w(_ s: String) -> CGFloat { ctx.resolve(Text(s).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width }
        if w(text) <= width { return text }
        var lo = 1, hi = text.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if w(String(text.prefix(mid)) + "…") <= width { lo = mid } else { hi = mid - 1 }
        }
        return lo >= 3 ? String(text.prefix(lo)) + "…" : nil
    }
}

/// Finder, copy path, and Trash, for whatever is under the pointer.
struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: Node?

    var body: some View {
        if let node, let r = model.result {
            let path = r.path(of: node)
            Button("Show in Finder") { model.reveal(path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Divider()
            if let why = model.refusal(for: node) {
                Button("Can't move: \(why)") {}.disabled(true)
            } else if model.treeInUse {
                Button("Move to Trash (after the \(model.checksRunning.isEmpty ? "clear" : "checks") finish\(model.checksRunning.isEmpty ? "es" : ""))") {}.disabled(true)
            } else {
                Button("Move to Trash…") { model.confirmSingle(node) }
            }
        }
    }
}

struct HoverLine: View {
    @Environment(\.uiScale) private var s
    let result: ScanResult
    let node: Node
    let mode: ColorMode
    /// Nodes are classes, so SwiftUI can't tell one changed; this makes it redraw after a clear.
    let revision: Int

    var body: some View {
        let path = result.display(result.path(of: node))
        HStack(spacing: 14 * s) {
            RoundedRectangle(cornerRadius: 3)
                .fill(mode == .kind ? Palette.kind(node.kind) : Palette.age(Palette.ageFraction(days: node.meanAgeDays)))
                .frame(width: 11 * s, height: 11 * s)
            Text(path).siltFont(13, design: .monospaced).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Group {
                Text(Format.bytes(node.allocated)).foregroundStyle(Palette.ink).monospacedDigit()
                if node.reclaimable < node.allocated * 9 / 10 {
                    Text("frees \(Format.bytes(node.reclaimable))").foregroundStyle(Palette.ink2).monospacedDigit()
                }
                Text(node.kind.title).foregroundStyle(Palette.ink2)
                Text("changed \(Format.age(node.newestDate))").foregroundStyle(Palette.ink2)
                if node.fileCount > 1 { Text("\(Format.count(node.fileCount)) files").foregroundStyle(Palette.muted) }
            }
            .siltFont(13)
        }
        .frame(height: 22 * s)
    }
}

struct KindKey: View {
    @Environment(\.uiScale) private var s
    var body: some View {
        FlowLayout(spacing: 16 * s) {
            ForEach(Kind.allCases, id: \.self) { k in
                HStack(spacing: 6 * s) {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.kind(k)).frame(width: 11 * s, height: 11 * s)
                    Text(k.title).siltFont(12.5).foregroundStyle(Palette.ink2)
                }
            }
            HStack(spacing: 6 * s) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.smaller).frame(width: 11 * s, height: 11 * s)
                Text("Smaller items, grouped").siltFont(12.5).foregroundStyle(Palette.ink2)
            }
        }
    }
}

struct AgeKey: View {
    @Environment(\.uiScale) private var s
    var body: some View {
        HStack(spacing: 10 * s) {
            Text("Changed recently").siltFont(12.5).foregroundStyle(Palette.ink2)
            HStack(spacing: 2) {
                ForEach(0..<Palette.ramp.count, id: \.self) { i in
                    Rectangle().fill(Palette.age(Double(i) / Double(Palette.ramp.count - 1))).frame(width: 18 * s, height: 11 * s)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("5+ years untouched").siltFont(12.5).foregroundStyle(Palette.ink2)
            Text("· by the average age of the bytes inside").siltFont(12.5).foregroundStyle(Palette.muted)
        }
    }
}

/// The current folder's contents as a list, for reading exact sizes and walking in by name.
struct ChildList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s
    let result: ScanResult
    let focus: Node
    let revision: Int

    var body: some View {
        let kids = Array(focus.children.filter { $0.allocated > 0 || $0.flags.contains(.unreadable) }
            .sorted { $0.allocated > $1.allocated }.prefix(14))
        let largest = max(1, kids.map(\.allocated).max() ?? 1)
        VStack(spacing: 0) {
            if focus.parent != nil {
                row(icon: "arrow.turn.left.up", name: "Up to \(focus.parent!.parent == nil ? result.display(result.rootPath) : focus.parent!.name)",
                    node: nil, fraction: 0) { model.focus = focus.parent }
            }
            ForEach(kids, id: \.name) { c in
                row(icon: c.isDirectory ? "folder" : "doc", name: c.name, node: c, fraction: Double(c.allocated) / Double(largest)) {
                    if c.isDirectory && !c.children.isEmpty { model.focus = c } else { model.reveal(result.path(of: c)) }
                }
                .contextMenu { NodeMenu(node: c) }
            }
            let shownBytes = kids.reduce(0) { $0 + $1.allocated }
            let rest = focus.allocated - shownBytes
            if rest > 0 {
                HStack(spacing: 10 * s) {
                    Image(systemName: "ellipsis").frame(width: 18 * s).foregroundStyle(Palette.muted)
                    let n = max(0, focus.fileCount - kids.reduce(0) { $0 + $1.fileCount })
                    Text(n == 1 ? "1 smaller file" : "\(Format.count(n)) smaller files")
                        .siltFont(13.5).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text(Format.bytes(rest)).siltFont(13.5).monospacedDigit().foregroundStyle(Palette.ink2)
                }
                .padding(.horizontal, 14 * s).padding(.vertical, 7 * s)
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }

    private func row(icon: String, name: String, node: Node?, fraction: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10 * s) {
                Image(systemName: icon).siltFont(13).frame(width: 18 * s).foregroundStyle(Palette.ink2)
                Text(name).siltFont(13.5, .medium).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 180 * s, maxWidth: 320 * s, alignment: .leading)
                if let node, node.flags.contains(.unreadable) {
                    Spacer()
                    Label("macOS won't let Silt look inside", systemImage: "lock")
                        .siltFont(12.5).foregroundStyle(Palette.muted)
                } else if let node {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(model.colorMode == .kind ? Palette.kind(node.kind) : Palette.age(Palette.ageFraction(days: node.meanAgeDays)))
                            .frame(width: max(2, geo.size.width * min(1, fraction)), height: 8 * s)
                            .frame(maxHeight: .infinity)
                    }
                    Text("changed \(Format.age(node.newestDate))").siltFont(12.5).foregroundStyle(Palette.muted)
                        .frame(width: 140 * s, alignment: .trailing)
                    Text(Format.bytes(node.allocated)).siltFont(13.5).monospacedDigit().foregroundStyle(Palette.ink)
                        .frame(width: 80 * s, alignment: .trailing)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 14 * s)
            .padding(.vertical, 7 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
