import Testing
@testable import HexCore

struct VoiceCommandDetectorTests {
  @Test
  func detectsNewParagraph() {
    #expect(VoiceCommandDetector.detect("new paragraph") == .newParagraph)
    #expect(VoiceCommandDetector.detect("New Paragraph") == .newParagraph)
    #expect(VoiceCommandDetector.detect("NEW PARAGRAPH!") == .newParagraph)
  }

  @Test
  func detectsNewLine() {
    #expect(VoiceCommandDetector.detect("new line") == .newLine)
    #expect(VoiceCommandDetector.detect("next line") == .newLine)
  }

  @Test
  func detectsSelectAll() {
    #expect(VoiceCommandDetector.detect("select all") == .selectAll)
    #expect(VoiceCommandDetector.detect("Select All.") == .selectAll)
  }

  @Test
  func detectsUndoRedo() {
    #expect(VoiceCommandDetector.detect("undo") == .undo)
    #expect(VoiceCommandDetector.detect("undo that") == .undo)
    #expect(VoiceCommandDetector.detect("redo") == .redo)
    #expect(VoiceCommandDetector.detect("redo that") == .redo)
  }

  @Test
  func detectsPunctuation() {
    #expect(VoiceCommandDetector.detect("period") == .period)
    #expect(VoiceCommandDetector.detect("full stop") == .period)
    #expect(VoiceCommandDetector.detect("comma") == .comma)
    #expect(VoiceCommandDetector.detect("question mark") == .questionMark)
    #expect(VoiceCommandDetector.detect("exclamation mark") == .exclamationMark)
    #expect(VoiceCommandDetector.detect("exclamation point") == .exclamationMark)
  }

  @Test
  func doesNotMatchPartialText() {
    #expect(VoiceCommandDetector.detect("I want to start a new paragraph here") == nil)
    #expect(VoiceCommandDetector.detect("please undo the last change") == nil)
    #expect(VoiceCommandDetector.detect("hello world") == nil)
  }

  @Test
  func handlesWhitespaceAndPunctuation() {
    #expect(VoiceCommandDetector.detect("  new paragraph  ") == .newParagraph)
    #expect(VoiceCommandDetector.detect("undo.") == .undo)
    #expect(VoiceCommandDetector.detect("Select All!") == .selectAll)
  }

  @Test
  func returnsNilForEmptyString() {
    #expect(VoiceCommandDetector.detect("") == nil)
    #expect(VoiceCommandDetector.detect("   ") == nil)
  }
}
