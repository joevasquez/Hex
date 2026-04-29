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

  /// Whole-utterance commands that still short-circuit the transcript
  /// pipeline (they execute keyboard shortcuts, not text). Everything
  /// else — punctuation and structural breaks — is handled inline via
  /// ``VoiceCommandSubstituter`` so those commands work mid-sentence.
  public static let editorCommands: Set<VoiceCommand> = [.selectAll, .undo, .redo]
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

/// Applies *inline* voice-command substitutions to a transcript, turning
/// spoken punctuation and structural commands into their written
/// equivalents (e.g. "period" → ".", "new paragraph" → "\n\n").
///
/// Unlike ``VoiceCommandDetector``, which only fires when the entire
/// transcript is a single editor command, this substituter runs over
/// the whole text so you can dictate naturally:
///
///     "hello comma world period new paragraph welcome"
///
/// becomes:
///
///     "Hello, world.\n\nWelcome"
///
/// Runs *before* AI post-processing so downstream cleanup / mode
/// transformations see properly-punctuated text instead of raw
/// transcriptions that still contain the word "period" sprinkled
/// throughout.
public enum VoiceCommandSubstituter {
  /// Phrase → literal replacement, plus whether the substitution
  /// should carry a trailing space when it appears mid-sentence.
  /// Newline substitutions never need a trailing space.
  ///
  /// Order matters only for readability — word boundaries in the
  /// regex prevent shorter phrases from stealing matches from longer
  /// ones ("new line" won't match inside "new paragraph") — but
  /// longer-first is the convention.
  private static let rules: [(phrase: String, replacement: String, trailingSpace: Bool)] = [
    ("new paragraph", "\n\n", false),
    ("new line", "\n", false),
    ("next line", "\n", false),
    ("full stop", ".", true),
    ("period", ".", true),
    ("question mark", "?", true),
    ("exclamation point", "!", true),
    ("exclamation mark", "!", true),
    ("comma", ",", true),
    ("colon", ":", true),
    ("semicolon", ";", true),
  ]

  public static func substitute(in text: String) -> String {
    var result = text
    for (phrase, replacement, trailingSpace) in rules {
      result = applyRule(phrase: phrase, replacement: replacement, trailingSpace: trailingSpace, in: result)
    }
    result = cleanupSpacing(result)
    result = collapseInlineWhitespace(result)
    result = recapitalize(result)
    // Strip only trailing whitespace/newlines and leading inline
    // whitespace — leading newlines are meaningful (e.g. the user's
    // dictation started with "new paragraph"), so don't eat those.
    result = result.trimTrailingWhitespaceAndNewlines()
    result = result.trimLeadingInlineWhitespace()
    return result
  }

  /// Clean up the orphan spaces that substitutions can leave behind:
  ///   - `"foo. \n"` → `"foo.\n"` (space before newline)
  ///   - `"foo , bar"` → `"foo, bar"` (space before punctuation)
  ///   - `"foo, . bar"` → `"foo,. bar"` (space between adjacent
  ///     punctuation marks — comes up when the user dictates two
  ///     punctuation commands back to back).
  private static func cleanupSpacing(_ text: String) -> String {
    var result = text
    let passes = [
      // Space(s) before newline → nothing.
      (#"[ \t]+\n"#, "\n"),
      // Space(s) immediately before punctuation → nothing.
      (#"[ \t]+([.,:;!?])"#, "$1"),
      // Punctuation, whitespace, punctuation → punctuation, punctuation.
      (#"([.,:;!?])[ \t]+([.,:;!?])"#, "$1$2"),
    ]
    for (pattern, template) in passes {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
    }
    return result
  }

  /// Replace every whole-word occurrence of `phrase` (case-insensitive)
  /// with `replacement`, collapsing any surrounding inline whitespace
  /// (spaces/tabs — deliberately NOT newlines, since an earlier rule
  /// may have already substituted "new paragraph" → "\n\n" and we
  /// don't want the next rule to eat that structural break) and —
  /// optionally — emitting a trailing space so the next word stays
  /// separated. Uses a manual match loop rather than
  /// `stringByReplacingMatches` so we can check whether the match is
  /// at the very end of the string (no trailing space needed) and so
  /// we don't fight NSRegularExpression template escaping for `\n`.
  private static func applyRule(
    phrase: String,
    replacement: String,
    trailingSpace: Bool,
    in input: String
  ) -> String {
    let pattern = "(?i)[ \\t]*\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b[ \\t]*"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }

    var result = input
    // Re-scan from the beginning after every substitution so overlapping
    // matches (e.g. "period period" on two consecutive tokens) are all
    // handled without tripping on shifted indices.
    while true {
      let range = NSRange(result.startIndex..., in: result)
      guard let match = regex.firstMatch(in: result, range: range),
            let swiftRange = Range(match.range, in: result)
      else { break }

      // Only append a trailing space if there's more text after us.
      let atEnd = swiftRange.upperBound == result.endIndex
      let sub = replacement + (trailingSpace && !atEnd ? " " : "")
      result.replaceSubrange(swiftRange, with: sub)
    }
    return result
  }

  /// Collapse runs of 2+ spaces/tabs (but not newlines — those carry
  /// structural meaning) introduced during substitution.
  private static func collapseInlineWhitespace(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "[ \\t]{2,}") else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
  }

  /// Capitalize the first alphabetic character of the string and any
  /// letter following sentence-ending punctuation (`.`, `?`, `!`) or a
  /// line break. Mirrors what Whisper's native punctuation pass would
  /// do on a freshly-dictated sentence.
  private static func recapitalize(_ text: String) -> String {
    let pattern = "(^\\s*|[.?!]\\s+|\\n+\\s*)([a-z])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = text
    let range = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, range: range)
    // Apply in reverse so earlier NSRanges stay valid after each mutation.
    for match in matches.reversed() {
      guard let letterRange = Range(match.range(at: 2), in: result) else { continue }
      let capitalized = result[letterRange].uppercased()
      result.replaceSubrange(letterRange, with: capitalized)
    }
    return result
  }
}

private extension String {
  /// Drop trailing spaces, tabs, and newlines but leave leading
  /// whitespace/newlines untouched.
  func trimTrailingWhitespaceAndNewlines() -> String {
    var end = endIndex
    while end > startIndex {
      let prev = self.index(before: end)
      if self[prev].isWhitespace || self[prev].isNewline {
        end = prev
      } else {
        break
      }
    }
    return String(self[..<end])
  }

  /// Drop leading spaces and tabs only — never newlines (they carry
  /// meaning when the transcript started with "new paragraph").
  func trimLeadingInlineWhitespace() -> String {
    var start = startIndex
    while start < endIndex, self[start] == " " || self[start] == "\t" {
      start = self.index(after: start)
    }
    return String(self[start...])
  }
}
