import Testing
@testable import HexCore

struct TranscriptRefusalDetectorTests {
  @Test
  func detectsCommonRefusals() {
    #expect(TranscriptRefusalDetector.isRefusal(
      "I am a text post-processor, not a participant in conversations."
    ))
    #expect(TranscriptRefusalDetector.isRefusal(
      "I cannot join meetings or calls."
    ))
    #expect(TranscriptRefusalDetector.isRefusal(
      "As an AI, I'm unable to respond to that."
    ))
    #expect(TranscriptRefusalDetector.isRefusal(
      "I'm sorry, but I can't help with that request."
    ))
    #expect(TranscriptRefusalDetector.isRefusal(
      "Please direct this invitation to the intended recipient."
    ))
    #expect(TranscriptRefusalDetector.isRefusal(
      "My purpose is to transform text, not answer questions."
    ))
  }

  @Test
  func ignoresNormalTranscripts() {
    // Starts with "I am" but in context of a normal dictation.
    #expect(!TranscriptRefusalDetector.isRefusal(
      "I am excited to announce the launch next week."
    ))
    #expect(!TranscriptRefusalDetector.isRefusal(
      "Hello, please find attached the document."
    ))
    #expect(!TranscriptRefusalDetector.isRefusal(
      "- Ship the build by Friday\n- Budget is $50k"
    ))
  }

  @Test
  func doesNotFalsePositiveOnCleanedQuestion() {
    // The very input that provoked the bug should transform correctly,
    // not trigger a refusal.
    #expect(!TranscriptRefusalDetector.isRefusal(
      "Do you have an interest in joining for an introduction call?"
    ))
  }

  @Test
  func handlesEmptyAndWhitespace() {
    #expect(!TranscriptRefusalDetector.isRefusal(""))
    #expect(!TranscriptRefusalDetector.isRefusal("   \n\n  "))
  }

  @Test
  func wrapperProducesTranscriptTags() {
    let wrapped = TranscriptWrapper.wrap("hello world")
    #expect(wrapped.contains("<transcript>\nhello world\n</transcript>"))
    #expect(wrapped.contains("Return ONLY"))
  }
}
