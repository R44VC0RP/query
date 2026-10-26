import Foundation
import SwiftUI

/// The light behind the card: a deep base, a body color and a highlight
/// mixed by the smoke, plus the accent for focus and the beacon.
struct Palette {
    let deep: SIMD3<Float>
    let body: SIMD3<Float>
    let highlight: SIMD3<Float>
    let accent: SIMD3<Float>

    static let presets: [String: Palette] = [
        "indigo": Palette(deep: [0.16, 0.18, 0.62], body: [0.47, 0.30, 0.92], highlight: [0.90, 0.52, 0.78], accent: [0.52, 0.50, 1.00]),
        "ember": Palette(deep: [0.45, 0.10, 0.04], body: [0.95, 0.42, 0.12], highlight: [1.00, 0.75, 0.40], accent: [1.00, 0.58, 0.28]),
        "jade": Palette(deep: [0.03, 0.30, 0.22], body: [0.15, 0.75, 0.55], highlight: [0.65, 0.95, 0.80], accent: [0.32, 0.85, 0.64]),
        "ocean": Palette(deep: [0.03, 0.17, 0.45], body: [0.10, 0.55, 0.95], highlight: [0.55, 0.90, 1.00], accent: [0.32, 0.66, 1.00]),
        "rose": Palette(deep: [0.40, 0.06, 0.22], body: [0.92, 0.32, 0.55], highlight: [1.00, 0.72, 0.80], accent: [1.00, 0.48, 0.66]),
        "gold": Palette(deep: [0.36, 0.24, 0.04], body: [0.88, 0.66, 0.22], highlight: [1.00, 0.90, 0.62], accent: [0.96, 0.78, 0.36]),
        "mono": Palette(deep: [0.16, 0.16, 0.18], body: [0.55, 0.55, 0.60], highlight: [0.92, 0.92, 0.95], accent: [0.86, 0.86, 0.90]),
    ]

    static let presetNames = presets.keys.sorted()

    /// A preset name or a hex color such as `#ff6a3d`.
    static func named(_ raw: String) -> Palette? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let preset = presets[name] { return preset }
        guard let color = parseHex(name) else { return nil }
        let white = SIMD3<Float>(repeating: 1)
        return Palette(
            deep: color * 0.35,
            body: color,
            highlight: color + (white - color) * 0.45,
            accent: color + (white - color) * 0.15
        )
    }

    private static func parseHex(_ raw: String) -> SIMD3<Float>? {
        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return SIMD3(
            Float((value >> 16) & 0xff) / 255,
            Float((value >> 8) & 0xff) / 255,
            Float(value & 0xff) / 255
        )
    }

    var accentColor: Color {
        Color(red: Double(accent.x), green: Double(accent.y), blue: Double(accent.z))
    }
}
