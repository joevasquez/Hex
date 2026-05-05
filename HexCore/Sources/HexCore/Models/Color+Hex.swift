import SwiftUI

public extension Color {
  /// Failable hex initializer used by integration tints (`#E44332` style).
  /// Accepts strings with or without a leading `#`. Returns nil for any
  /// non-6-char or non-hex input so call sites can fall back to a default.
  init?(hex: String) {
    var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    self = Color(red: r, green: g, blue: b)
  }
}
