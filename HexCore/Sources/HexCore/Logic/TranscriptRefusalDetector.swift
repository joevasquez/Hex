import Foundation

/// Wraps raw transcript text in the `<transcript>` tags that the
/// ``AIProcessingMode`` system prompt references, and detects when a
/// cloud LLM has still treated the transcript as a conversational
/// prompt (e.g. "I am a text post-processor, I cannot join calls…")
/// and refused to transform it.
///
/// Wrapping is the primary defense — tag-wrapped content is reliably
/// interpreted as data by Claude and GPT models. The refusal detector
/// is a safety net: when wrapping isn't enough (smaller models can
/// still break under pressure), we return the raw transcript instead
/// of the model's refusal so the user's dictation is never lost.
public enum TranscriptWrapper {
  /// Wrap `text` in the `<transcript>` tags the system prompt tells
  /// the model to look for. Prefaced with a short re-statement of the
  /// task so the model sees both the instruction and the framing every
  /// time.
  public static func wrap(_ text: String) -> String {
    """
    Apply the transformation from the system prompt to the text between the <transcript> tags. Return ONLY the transformed text — no tags, no preamble, no refusals.

    <transcript>
    \(text)
    </transcript>
    """
  }
}

public enum TranscriptRefusalDetector {
  /// Phrases that mark the start of a refusal / self-description by
  /// the model rather than a transformed transcript. Matched as
  /// whole-phrase prefixes followed by a word boundary (space, comma,
  /// period, etc.) so "I am a speaker" doesn't match "i am a" but
  /// "I am a language model" does. All comparisons are case-insensitive.
  private static let refusalPrefixes: [String] = [
    "i am a",
    "i'm a",
    "i cannot",
    "i can't",
    "i am unable",
    "i'm unable",
    "i am not able",
    "i'm not able",
    "as an ai",
    "as a text",
    "as a language model",
    "i apologize",
    "i'm sorry",
    "i am sorry",
    "please direct",
    "sorry, i",
    "i don't have",
    "i do not have",
    "my purpose is",
    "my role is",
  ]

  /// Returns true if `response` starts with one of the known refusal
  /// phrases. Callers should fall back to the raw transcript when
  /// this fires.
  ///
  /// Matches the prefix only when it ends at a natural boundary — a
  /// space, comma, period, colon, etc. — so an innocent sentence
  /// starting with the same characters doesn't trigger a false
  /// positive. "I am a speaker" → no match; "I am a text processor…"
  /// → match.
  public static func isRefusal(_ response: String) -> Bool {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let head = String(trimmed.prefix(100)).lowercased()
    return refusalPrefixes.contains { prefix in
      guard head.hasPrefix(prefix) else { return false }
      // Character immediately after the prefix must be a word boundary
      // (anything that isn't a letter or digit — includes end of string).
      let boundaryIndex = head.index(head.startIndex, offsetBy: prefix.count)
      guard boundaryIndex < head.endIndex else { return true }
      let next = head[boundaryIndex]
      return !next.isLetter && !next.isNumber
    }
  }
}
