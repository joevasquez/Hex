import Foundation

/// Voice commands that can be detected in transcribed text and executed
/// instead of pasting the raw transcription.
public enum VoiceCommand: Equatable, Sendable {
  case newParagraph
  case newLine
  case selectAll
  case undo
  case redo
  case period
  case comma
  case questionMark
  case exclamationMark
}

/// Detects voice commands from transcribed text.
///
/// A command is only matched if the entire transcript (after normalization)
/// matches a known command phrase. Partial matches within longer text
/// are intentionally not detected.
public enum VoiceCommandDetector {
  public static func detect(_ text: String) -> VoiceCommand? {
    let normalized = normalize(text)
    switch normalized {
    case "new paragraph": return .newParagraph
    case "new line", "next line": return .newLine
    case "select all": return .selectAll
    case "undo", "undo that": return .undo
    case "redo", "redo that": return .redo
    case "period", "full stop": return .period
    case "comma": return .comma
    case "question mark": return .questionMark
    case "exclamation mark", "exclamation point": return .exclamationMark
    default: return nil
    }
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
