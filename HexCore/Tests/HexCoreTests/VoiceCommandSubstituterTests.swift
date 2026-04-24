import Testing
@testable import HexCore

struct VoiceCommandSubstituterTests {
  // MARK: - Punctuation

  @Test
  func substitutesInlinePeriod() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "hello everyone period welcome")
        == "Hello everyone. Welcome"
    )
  }

  @Test
  func substitutesInlineComma() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "hello comma world")
        == "Hello, world"
    )
  }

  @Test
  func substitutesQuestionAndExclamation() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "is this working question mark")
        == "Is this working?"
    )
    #expect(
      VoiceCommandSubstituter.substitute(in: "watch out exclamation point")
        == "Watch out!"
    )
    #expect(
      VoiceCommandSubstituter.substitute(in: "amazing exclamation mark")
        == "Amazing!"
    )
  }

  @Test
  func substitutesColonAndSemicolon() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "three items colon apples bananas pears")
        == "Three items: apples bananas pears"
    )
    #expect(
      VoiceCommandSubstituter.substitute(in: "first semicolon second")
        == "First; second"
    )
  }

  @Test
  func substitutesFullStopAsPeriod() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "end of thought full stop next thought")
        == "End of thought. Next thought"
    )
  }

  // MARK: - Structural

  @Test
  func substitutesNewParagraph() {
    let result = VoiceCommandSubstituter.substitute(in: "first idea new paragraph second idea")
    #expect(result == "First idea\n\nSecond idea")
  }

  @Test
  func substitutesNewLine() {
    let result = VoiceCommandSubstituter.substitute(in: "line one new line line two")
    #expect(result == "Line one\nLine two")
    let alt = VoiceCommandSubstituter.substitute(in: "line one next line line two")
    #expect(alt == "Line one\nLine two")
  }

  // MARK: - Capitalization

  @Test
  func capitalizesAfterSentencePunctuation() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "one period two period three")
        == "One. Two. Three"
    )
  }

  @Test
  func capitalizesAfterLineBreaks() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "alpha new paragraph beta new line gamma")
        == "Alpha\n\nBeta\nGamma"
    )
  }

  @Test
  func capitalizesFirstCharacter() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "welcome to the meeting")
        == "Welcome to the meeting"
    )
  }

  // MARK: - Edge cases

  @Test
  func leavesTextWithNoCommandsAlone() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "hello world")
        == "Hello world"
    )
  }

  @Test
  func doesNotMatchInsideOtherWords() {
    // "periodic" contains "period" but should not be substituted.
    #expect(
      VoiceCommandSubstituter.substitute(in: "the periodic table is cool")
        == "The periodic table is cool"
    )
  }

  @Test
  func handlesCaseInsensitively() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "hello Period world")
        == "Hello. World"
    )
    #expect(
      VoiceCommandSubstituter.substitute(in: "new PARAGRAPH here")
        == "\n\nHere"
    )
  }

  @Test
  func handlesMultipleConsecutiveCommands() {
    #expect(
      VoiceCommandSubstituter.substitute(in: "yes comma period new paragraph done")
        == "Yes,.\n\nDone"
    )
  }

  @Test
  func handlesEmptyAndWhitespaceInput() {
    #expect(VoiceCommandSubstituter.substitute(in: "") == "")
    #expect(VoiceCommandSubstituter.substitute(in: "   ") == "")
  }

  @Test
  func handlesCommandAtStart() {
    // Leading commands are weird but should not crash and should still
    // capitalize whatever follows.
    let out = VoiceCommandSubstituter.substitute(in: "period hello world")
    #expect(out == ". Hello world")
  }

  @Test
  func handlesCommandAtEnd() {
    // Trailing punctuation commands shouldn't leave a dangling space.
    #expect(
      VoiceCommandSubstituter.substitute(in: "the end period")
        == "The end."
    )
  }

  @Test
  func realisticConferenceNote() {
    let input = "the keynote was strong period three takeaways colon new line first open source is eating the stack new line second distribution still wins new line third evaluations are underrated"
    let expected = "The keynote was strong. Three takeaways:\nFirst open source is eating the stack\nSecond distribution still wins\nThird evaluations are underrated"
    #expect(VoiceCommandSubstituter.substitute(in: input) == expected)
  }
}
