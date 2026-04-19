import Foundation

/// Strips Whisper's non-speech diagnostic tokens from a transcript.
///
/// WhisperKit (and Whisper models in general) occasionally emit diagnostic
/// tags in place of non-speech audio segments: `[BLANK_AUDIO]`,
/// `[ Silence ]`, `[Music]`, `[APPLAUSE]`, `[LAUGHTER]`, `[INAUDIBLE]`,
/// `[Music Playing]`, etc. Those are useful for research / debugging but
/// absolutely don't belong in a user's pasted note or clipboard.
///
/// This cleaner removes any bracketed run of letters/spaces/underscores/
/// hyphens and tidies up the whitespace left behind (double spaces, triple
/// newlines, space-before-punctuation). Users effectively never produce
/// literal brackets in dictation, so false positives on real content are
/// rare — and the note is editable if it ever matters.
public enum WhisperOutputCleaner {
  public static func clean(_ text: String) -> String {
    // Match any bracketed block of letters / spaces / underscores / hyphens.
    // Case-insensitive so it catches both [BLANK_AUDIO] and [ Silence ].
    let tagPattern = #"\[\s*[A-Za-z][A-Za-z _-]*\s*\]"#
    var cleaned = text.replacingOccurrences(
      of: tagPattern,
      with: "",
      options: .regularExpression
    )

    // Collapse runs of spaces / tabs.
    cleaned = cleaned.replacingOccurrences(
      of: #"[ \t]{2,}"#,
      with: " ",
      options: .regularExpression
    )

    // Collapse three-or-more newlines down to a single blank line.
    cleaned = cleaned.replacingOccurrences(
      of: #"\n{3,}"#,
      with: "\n\n",
      options: .regularExpression
    )

    // Kill the "space-before-punctuation" artifact that shows up when a
    // tag was wedged between a word and its trailing comma / period.
    cleaned = cleaned.replacingOccurrences(
      of: #" +([.,!?;:])"#,
      with: "$1",
      options: .regularExpression
    )

    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
