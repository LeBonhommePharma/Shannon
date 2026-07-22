import XCTest
@testable import PillCore

final class VoiceCommandTests: XCTestCase {

    private let parser = VoiceCommandParser()

    // MARK: Recognised commands

    func testConfirmSynonyms() {
        for phrase in ["confirm", "yes", "approve", "Yes", "  YES  ", "yes."] {
            XCTAssertEqual(parser.parse(phrase), .confirm, "failed on \(phrase)")
        }
    }

    func testDenySynonyms() {
        for phrase in ["deny", "no", "cancel", "No!", "decline"] {
            XCTAssertEqual(parser.parse(phrase), .deny, "failed on \(phrase)")
        }
    }

    func testMultiWordCommands() {
        XCTAssertEqual(parser.parse("show status"), .showStatus)
        XCTAssertEqual(parser.parse("run benchmark"), .runBenchmark)
        XCTAssertEqual(parser.parse("run the benchmark"), .runBenchmark)
        XCTAssertEqual(parser.parse("what's docking?"), .whatsDocking)
        XCTAssertEqual(parser.parse("whats docking"), .whatsDocking)
        XCTAssertEqual(parser.parse("pause"), .pause)
        XCTAssertEqual(parser.parse("stop"), .pause)
    }

    // MARK: The safety rule — a command must be the whole utterance

    func testEmbeddedCommandWordsAreQueriesNotCommands() {
        // This is the property that keeps "commit and push" from being
        // approved by a sentence that merely contains "yes".
        XCTAssertEqual(
            parser.parse("yes but check the ligand first"),
            .query("yes but check the ligand first")
        )
        XCTAssertEqual(
            parser.parse("no problem, run the benchmark later"),
            .query("no problem, run the benchmark later")
        )
        XCTAssertEqual(
            parser.parse("confirm that the docking finished"),
            .query("confirm that the docking finished")
        )
    }

    func testSubstringsOfCommandWordsDoNotMatch() {
        // "north" contains "no"; "yesterday" contains "yes".
        XCTAssertEqual(parser.parse("north"), .query("north"))
        XCTAssertEqual(parser.parse("yesterday"), .query("yesterday"))
        XCTAssertEqual(parser.parse("nobody"), .query("nobody"))
        XCTAssertEqual(parser.parse("statusline"), .query("statusline"))
    }

    // MARK: Queries

    func testArbitraryTextBecomesQueryPreservingOriginalCasing() {
        XCTAssertEqual(
            parser.parse("What is the RMSD for 1G9V?"),
            .query("What is the RMSD for 1G9V?")
        )
    }

    func testQueryTrimsSurroundingWhitespaceOnly() {
        XCTAssertEqual(parser.parse("  dock 1a4g  "), .query("dock 1a4g"))
    }

    // MARK: Empty input

    func testEmptyAndPunctuationOnlyYieldNil() {
        XCTAssertNil(parser.parse(""))
        XCTAssertNil(parser.parse("   "))
        XCTAssertNil(parser.parse("..."))
        XCTAssertNil(parser.parse("!?"))
    }

    // MARK: Tokenizer

    func testTokenizerKeepsApostrophesAndDropsPunctuation() {
        XCTAssertEqual(VoiceCommandParser.tokenize("what's docking?"), ["what's", "docking"])
        XCTAssertEqual(VoiceCommandParser.tokenize("Yes, please!"), ["yes", "please"])
        XCTAssertEqual(VoiceCommandParser.tokenize("1G9V"), ["1g9v"])
    }
}

final class AnnouncementQueueTests: XCTestCase {

    func testFifoWithinSamePriority() {
        var q = AnnouncementQueue()
        q.enqueue(Announcement(text: "first"))
        q.enqueue(Announcement(text: "second"))
        XCTAssertEqual(q.next()?.text, "first")
        XCTAssertEqual(q.next()?.text, "second")
        XCTAssertNil(q.next())
    }

    func testHigherPriorityJumpsAheadButKeepsOrderWithinPriority() {
        var q = AnnouncementQueue()
        q.enqueue(Announcement(text: "routine 1", priority: .routine))
        q.enqueue(Announcement(text: "routine 2", priority: .routine))
        q.enqueue(Announcement(text: "urgent 1", priority: .urgent))
        q.enqueue(Announcement(text: "urgent 2", priority: .urgent))

        XCTAssertEqual(q.next()?.text, "urgent 1")
        XCTAssertEqual(q.next()?.text, "urgent 2")
        XCTAssertEqual(q.next()?.text, "routine 1")
        XCTAssertEqual(q.next()?.text, "routine 2")
    }

    func testHoldSuppressesDelivery() {
        var q = AnnouncementQueue()
        q.enqueue(Announcement(text: "hello"))
        q.hold()
        XCTAssertNil(q.next(), "must not speak while held")
        XCTAssertEqual(q.count, 1, "held items are retained, not dropped")
    }

    func testResumeDropsStaleRoutineButKeepsUrgent() {
        // Routine chatter that piled up while the AirPods were off is noise;
        // "agent blocked" is still true.
        var q = AnnouncementQueue()
        q.hold()
        q.enqueue(Announcement(text: "target 1 complete", priority: .routine))
        q.enqueue(Announcement(text: "target 2 complete", priority: .routine))
        q.enqueue(Announcement(text: "agent blocked", priority: .urgent))
        q.enqueue(Announcement(text: "benchmark done", priority: .important))

        let released = q.release()
        XCTAssertEqual(released.map(\.text), ["agent blocked", "benchmark done"])
        XCTAssertTrue(q.isEmpty)
        XCTAssertFalse(q.isHeld)
    }

    func testRoutineIsKeptWhenDroppingDisabled() {
        var q = AnnouncementQueue()
        q.dropRoutineOnResume = false
        q.hold()
        q.enqueue(Announcement(text: "target 1 complete", priority: .routine))
        XCTAssertEqual(q.release().map(\.text), ["target 1 complete"])
    }

    func testClearEmptiesEverything() {
        var q = AnnouncementQueue()
        q.enqueue(Announcement(text: "a", priority: .urgent))
        q.clear()
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.next())
    }
}
