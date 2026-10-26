import SiltCore
import SwiftUI

/// Every byte on the disk, layered by when it last changed: the newest on top and the
/// oldest settled at the bottom, each layer as thick as the space it holds.
struct StrataSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            SectionHeading(title: "How long since things changed",
                           detail: "Every file, layered by when its contents last changed, as of the scan. Each layer is as thick as the space it holds.")
            if let r = model.result {
                strata(r.strata)
            } else {
                Placeholder(text: "The layers appear when the scan finishes.")
            }
        }
    }

    private func strata(_ bytes: [Int64]) -> some View {
        let total = max(1, bytes.reduce(0, +))
        let height = 380 * s
        let minimum = 28 * s
        // Thin layers get a floor so their label fits; the rest share what's left in proportion.
        let floored = bytes.map { Double($0) / Double(total) * height < minimum && $0 > 0 }
        let reserved = CGFloat(floored.filter { $0 }.count) * minimum
        let flexible = bytes.enumerated().filter { !floored[$0.offset] }.reduce(0) { $0 + $1.element }
        return VStack(spacing: 2) {
            ForEach(Stratum.allCases, id: \.self) { band in
                let b = bytes[band.rawValue]
                if b > 0 {
                    let t = (Double(band.rawValue) + 0.5) / Double(Stratum.allCases.count)
                    let h = floored[band.rawValue] ? minimum
                        : max(minimum, (height - reserved) * CGFloat(Double(b) / Double(max(1, flexible))))
                    HStack {
                        Text(band.title).siltFont(14, .semibold)
                        Spacer()
                        Text("\(Format.bytes(b)) · \(Int((Double(b) / Double(total) * 100).rounded()))%")
                            .siltFont(14).monospacedDigit()
                    }
                    .foregroundStyle(Palette.label(onAge: t))
                    .padding(.horizontal, 14 * s)
                    .frame(height: h)
                    .background(Palette.age(t))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
