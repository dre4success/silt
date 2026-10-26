import SiltCore
import SwiftUI

/// The top of the page: one headline number, and the whole disk as one bar.
struct HeaderSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * s) {
            Text(model.target == .wholeDisk
                 ? "\(model.volume.name) · \(Format.bytes(model.volume.capacity))"
                 : "\(model.target.title) on \(model.volume.name)")
                .siltFont(14, .medium)
                .foregroundStyle(Palette.ink2)

            if model.scanning { progress } else { headline }

            let segments = model.diskSegments
            DiskBar(segments: segments).frame(height: 30 * s)
            FlowLayout(spacing: 18 * s, lineSpacing: 8 * s) {
                ForEach(segments) { seg in
                    HStack(spacing: 7 * s) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 3).fill(seg.color)
                            if seg.hatched { Hatch().clipShape(RoundedRectangle(cornerRadius: 3)) }
                        }
                        .frame(width: 11 * s, height: 11 * s)
                        Text(seg.title).siltFont(13).foregroundStyle(Palette.ink)
                        Text(Format.bytes(seg.bytes)).siltFont(13).monospacedDigit().foregroundStyle(Palette.ink2)
                    }
                }
            }
            if model.target == .wholeDisk, model.volume.purgeable > 1_000_000_000 {
                // The amount stands out in the accent colour (not a bar colour, so it isn't read
                // as a section of the bar); it explains why System Settings shows more free space.
                (Text("On top of the free space, macOS can purge ")
                 + Text(Format.bytes(model.volume.purgeable)).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                 + Text(" by itself when it needs room (iCloud copies, caches it manages). System Settings counts that as free too, so it shows about \(Format.bytes(model.volume.free + model.volume.purgeable)) available."))
                    .siltFont(14).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 12 * s) {
                Text(Format.bytes(model.clearableTotal))
                    .siltFont(60, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                Text("you can clear").siltFont(24).foregroundStyle(Palette.ink2)
            }
            let rebuild = model.rebuildableTotal == 0 ? "All of it needs a look first."
                : "\(Format.bytes(model.rebuildableTotal)) of it rebuilds itself."
            Text(model.target == .wholeDisk ? "\(rebuild) \(Format.bytes(model.volume.free)) is free right now." : rebuild)
                .siltFont(16).foregroundStyle(Palette.ink2)
        }
    }

    private var progress: some View {
        let live = model.live
        let fraction = model.target == .wholeDisk && model.volume.dataUsed > 0
            ? min(1, Double(live.bytes) / Double(model.volume.dataUsed)) : nil
        let seconds = Int(Date().timeIntervalSince(model.scanStarted))
        return VStack(alignment: .leading, spacing: 8 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 12 * s) {
                Text(Format.bytes(live.bytes)).siltFont(60, .semibold).monospacedDigit().foregroundStyle(Palette.ink)
                Text("looked at so far").siltFont(24).foregroundStyle(Palette.ink2)
            }
            if let fraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("\(Format.count(live.files)) files in \(Format.count(live.folders)) folders · \(seconds) s")
                .siltFont(13).monospacedDigit().foregroundStyle(Palette.ink2)
            Text(live.current.isEmpty ? " " : live.current)
                .siltFont(12, design: .monospaced).foregroundStyle(Palette.muted)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

struct DiskBar: View {
    let segments: [DiskSegment]

    var body: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.bytes > 0 }
            let total = max(1, visible.reduce(0) { $0 + $1.bytes })
            let gap: CGFloat = 2
            let usable = max(0, geo.size.width - gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: gap) {
                ForEach(visible) { seg in
                    ZStack {
                        Rectangle().fill(seg.color)
                        if seg.hatched { Hatch() }
                    }
                    .frame(width: usable * CGFloat(seg.bytes) / CGFloat(total))
                    .help("\(seg.title): \(Format.bytes(seg.bytes))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.25), value: total)
        }
    }
}

/// Shown when macOS is keeping parts of the disk from Silt.
struct AccessNote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s

    var body: some View {
        let hidden = model.diskSegments.first { $0.id == "unseen" }?.bytes ?? 0
        HStack(alignment: .top, spacing: 14 * s) {
            Image(systemName: "lock").font(.system(size: 18 * s)).foregroundStyle(Palette.ink2)
            VStack(alignment: .leading, spacing: 8 * s) {
                Text("macOS is keeping \(Format.bytes(hidden)) from Silt")
                    .siltFont(15, .semibold).foregroundStyle(Palette.ink)
                Text("\(model.result?.unreadable.count ?? 0) folders, mostly other apps' private data, can only be measured with Full Disk Access. Turn it on for Silt in System Settings, then rescan.")
                    .siltFont(13.5).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10 * s) {
                    Button("Open Privacy Settings") { model.openPrivacySettings() }
                    Button("Rescan") { model.scan() }.disabled(model.working != nil)
                }
                .controlSize(.regular)
            }
            Spacer(minLength: 0)
        }
        .padding(16 * s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }
}
