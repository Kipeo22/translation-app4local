import Testing
@testable import Kotoba

struct TranslationCoreTests {
    @Test func explicitDirectionsOverrideShortAmbiguousText() {
        #expect(TranslationDirection.toEnglish.target(for: "OK") == "English")
        #expect(TranslationDirection.toJapanese.target(for: "123") == "Japanese")
        #expect(TranslationDirection.automatic.target(for: "") == nil)
    }

    @Test func japaneseAndEnglishAreDetected() {
        #expect(TranslationDirection.automatic.target(for: "この資料を金曜日まで共有しないでください。") == "English")
        #expect(TranslationDirection.automatic.target(for: "Please do not share this document until Friday.") == "Japanese")
    }

    @Test func streamAccumulatesUnicodeAndRequiresFinalMarker() throws {
        var stream = OllamaAccumulator()
        try stream.consume(#"{"message":{"content":"金曜日まで"},"done":false}"#)
        try stream.consume("")
        try stream.consume(#"{"message":{"content":"共有しないでください。"},"done":false}"#)
        #expect(stream.text == "金曜日まで共有しないでください。")
        #expect(throws: (any Error).self) { try stream.validateCompletion() }
        try stream.consume(#"{"message":{"content":""},"done":true,"done_reason":"stop"}"#)
        try stream.validateCompletion()
    }

    @Test func outputLimitIsNotReportedAsComplete() throws {
        var stream = OllamaAccumulator()
        #expect(throws: (any Error).self) {
            try stream.consume(#"{"message":{"content":"途中"},"done":true,"done_reason":"length"}"#)
        }
        #expect(!stream.finished)
    }

    @Test func serverErrorAndMalformedResponseAreNotTranslations() {
        var stream = OllamaAccumulator()
        #expect(throws: (any Error).self) { try stream.consume(#"{"error":"model not found"}"#) }
        #expect(throws: (any Error).self) { try stream.consume("<html>error</html>") }
    }

    @Test func emptyCompletionFails() throws {
        var stream = OllamaAccumulator()
        try stream.consume(#"{"message":{"content":""},"done":true}"#)
        #expect(throws: (any Error).self) { try stream.validateCompletion() }
    }
}
