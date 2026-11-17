import SwiftUI

/// How a fixture mixes colour: additive RGB (LED emitters) or subtractive CMY (flags).
enum ColorMixKind {
    case rgb, cmy

    /// Background of the mark, dark for RGB (light adds up) and light for CMY (filters stack up).
    fileprivate var tile: Color {
        switch self {
        case .rgb: return Color(red: 0.07, green: 0.07, blue: 0.09)
        case .cmy: return Color(red: 0.95, green: 0.95, blue: 0.96)
        }
    }

    /// Per-letter colours, readable on this kind's tile.
    fileprivate var letters: [(String, Color)] {
        switch self {
        case .rgb: return [("R", Color(red: 1.0, green: 0.30, blue: 0.30)),
                           ("G", Color(red: 0.25, green: 0.92, blue: 0.42)),
                           ("B", Color(red: 0.36, green: 0.55, blue: 1.0))]
        case .cmy: return [("C", Color(red: 0.0, green: 0.60, blue: 0.86)),
                           ("M", Color(red: 0.86, green: 0.0, blue: 0.52)),
                           ("Y", Color(red: 0.80, green: 0.66, blue: 0.0))]
        }
    }
}

/// "RGB" / "CMY" as a coloured wordmark.
struct ColorMixBadge: View {
    let kind: ColorMixKind
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(kind.letters.enumerated()), id: \.offset) { _, letter in
                Text(letter.0).foregroundColor(letter.1)
            }
        }
        .font(.system(size: compact ? 11 : 15, weight: .heavy, design: .rounded))
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 1 : 2)
        .background(RoundedRectangle(cornerRadius: compact ? 5 : 6).fill(kind.tile))
    }
}
