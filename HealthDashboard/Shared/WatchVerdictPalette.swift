import SwiftUI

// Display-only color/label mapping shared by the Watch app and the Watch
// complication widget extension, so both render the same verdict colors and
// wording from a single source. ReadinessEngine's actual scoring/thresholds are
// untouched and live entirely on the iPhone — this just maps an already-computed
// ReadinessStatus to a color/string for the Watch's smaller UI surfaces.
enum WatchVerdictPalette {
    static func color(for status: ReadinessStatus) -> Color {
        switch status {
        case .green:  return Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
        case .yellow: return Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
        case .red:    return Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x30 / 255)
        }
    }

    /// Watch-specific short label — distinct wording from the iPhone's
    /// "Green/Yellow/Red" StatusPill, sized for the small Watch face.
    static func verdictLabel(for status: ReadinessStatus) -> String {
        switch status {
        case .green:  return "Ready"
        case .yellow: return "Moderate"
        case .red:    return "High Load"
        }
    }
}
