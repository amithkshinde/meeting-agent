import XCTest
@testable import MeetingAgent

final class TranscriptBuilderTests: XCTestCase {
    private func tok(_ t: String, _ s: Double, _ e: Double) -> TimedToken { TimedToken(text: t, start: s, end: e) }

    func testSentencesSplitOnPunctuationAndPauses() {
        let tokens = [tok("▁Hello", 0, 0.4), tok("▁the", 0.5, 0.7), tok("re", 0.7, 0.9), tok(".", 0.9, 1.0),
                      tok("▁How", 1.1, 1.3), tok("▁are", 1.3, 1.5), tok("▁you", 1.5, 1.8), tok("?", 1.8, 1.9),
                      tok("▁Fine", 5.0, 5.4)]
        let sentences = TranscriptBuilder.utterances(from: tokens)
        XCTAssertEqual(sentences.map { $0.text }, ["Hello there.", "How are you?", "Fine"])
    }

    func testMergedTranscriptUsesTheAppsLineFormatAndRemovesEchoes() {
        let them = [Utterance(start: 0, end: 10, text: "We should ship the release on Friday afternoon")]
        let you = [Utterance(start: 0, end: 11, text: "we should ship the release on friday afternoon"),
                   Utterance(start: 20, end: 25, text: "Sounds good to me")]
        let kept = TranscriptBuilder.removeEchoes(you: you, them: them)
        let text = TranscriptBuilder.merge(you: kept, them: them)
        XCTAssertEqual(text, "[00:10] Them: We should ship the release on Friday afternoon\n[00:25] You: Sounds good to me\n")
        let parsed = Transcript.parse(text)
        XCTAssertEqual(parsed.map { $0.speaker }, ["Them", "You"])
        XCTAssertEqual(parsed.first?.time, 10)
    }

    func testEchoCutIntoDifferentSentencesIsStillRemoved() {
        let them = [Utterance(start: 0, end: 4, text: "We should ship the release"),
                    Utterance(start: 4.2, end: 7, text: "on Friday afternoon if testing passes")]
        let you = [Utterance(start: 0.4, end: 7.4, text: "ship the release on Friday afternoon if testing passes"),
                   Utterance(start: 9, end: 11, text: "Yes I agree with that")]
        let kept = TranscriptBuilder.removeEchoes(you: you, them: them)
        XCTAssertEqual(kept.map { $0.text }, ["Yes I agree with that"])
    }

    func testShortYouLinesAreKept() {
        let them = [Utterance(start: 0, end: 4, text: "Is that okay with you")]
        let you = [Utterance(start: 1, end: 2, text: "Yes okay")]
        XCTAssertEqual(TranscriptBuilder.removeEchoes(you: you, them: them).count, 1)
    }
}
