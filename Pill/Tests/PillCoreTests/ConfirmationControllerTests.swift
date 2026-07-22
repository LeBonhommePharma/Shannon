import XCTest
@testable import PillCore

@MainActor
final class ConfirmationControllerTests: XCTestCase {

    private let deg = Double.pi / 180

    private func makeController(
        available: Bool = true
    ) -> (ConfirmationController, StubHeadphoneMotionProvider, RecordingFeedback) {
        let provider = StubHeadphoneMotionProvider()
        provider.isAvailable = available
        let feedback = RecordingFeedback()
        return (ConfirmationController(provider: provider, feedback: feedback), provider, feedback)
    }

    /// Emit a full nod or shake through the stub provider.
    ///
    /// The controller hops each sample to the main actor, because real
    /// CoreMotion delivers on a background operation queue. Awaiting a task
    /// enqueued after the emits drains them in FIFO order.
    private func emitGesture(
        _ provider: StubHeadphoneMotionProvider,
        nod: Bool,
        at t: TimeInterval = 0
    ) async {
        let peak = 25 * deg
        provider.emit(HeadAttitudeSample(pitch: 0, yaw: 0, timestamp: t))
        provider.emit(HeadAttitudeSample(pitch: nod ? peak : 0, yaw: nod ? 0 : peak, timestamp: t + 0.2))
        provider.emit(HeadAttitudeSample(pitch: 0, yaw: 0, timestamp: t + 0.4))
        await drain()
    }

    private func drain() async {
        await Task { @MainActor in }.value
    }

    // MARK: Gating

    func testNoPromptMeansProviderIsNotEvenRunning() {
        let (controller, provider, _) = makeController()
        XCTAssertFalse(controller.isAwaitingConfirmation)
        XCTAssertFalse(provider.isRunning)
    }

    func testAskStartsAndAnswerStopsTheMotionProvider() {
        let (controller, provider, _) = makeController()
        controller.ask(ConfirmationPrompt(question: "Dock this ligand?")) { _, _ in }
        XCTAssertTrue(controller.isAwaitingConfirmation)
        XCTAssertTrue(provider.isRunning)

        controller.answer(.confirmed)
        XCTAssertFalse(controller.isAwaitingConfirmation)
        XCTAssertFalse(provider.isRunning)
    }

    func testGesturesAfterAnsweringAreIgnored() async {
        let (controller, provider, _) = makeController()
        var answers: [ConfirmationAnswer] = []
        controller.ask(ConfirmationPrompt(question: "Commit and push?")) { a, _ in answers.append(a) }
        controller.answer(.confirmed)

        // Nodding at an unprompted pill must do nothing.
        await emitGesture(provider, nod: true, at: 10)
        XCTAssertEqual(answers, [.confirmed])
    }

    // MARK: Gesture answers

    func testNodConfirms() async {
        let (controller, provider, _) = makeController()
        var received: (ConfirmationAnswer, ConfirmationSource)?
        controller.ask(ConfirmationPrompt(question: "Dock this ligand?")) { received = ($0, $1) }

        await emitGesture(provider, nod: true)
        XCTAssertEqual(received?.0, .confirmed)
        XCTAssertEqual(received?.1, .gesture)
        XCTAssertEqual(controller.flash, .confirm)
    }

    func testShakeDenies() async {
        let (controller, provider, _) = makeController()
        var received: (ConfirmationAnswer, ConfirmationSource)?
        controller.ask(ConfirmationPrompt(question: "Dock this ligand?")) { received = ($0, $1) }

        await emitGesture(provider, nod: false)
        XCTAssertEqual(received?.0, .denied)
        XCTAssertEqual(received?.1, .gesture)
        XCTAssertEqual(controller.flash, .deny)
    }

    func testClickIsReportedAsClickSource() {
        let (controller, _, _) = makeController()
        var received: (ConfirmationAnswer, ConfirmationSource)?
        controller.ask(ConfirmationPrompt(question: "Commit?")) { received = ($0, $1) }
        controller.answer(.denied)
        XCTAssertEqual(received?.1, .click)
    }

    // MARK: Single-answer guarantee

    func testPromptIsAnsweredAtMostOnce() async {
        let (controller, provider, _) = makeController()
        var count = 0
        controller.ask(ConfirmationPrompt(question: "Push?")) { _, _ in count += 1 }

        await emitGesture(provider, nod: true)
        await emitGesture(provider, nod: true, at: 10)   // well past the lockout
        controller.answer(.denied)

        XCTAssertEqual(count, 1)
    }

    func testClickLosingToGestureIsDropped() async {
        let (controller, provider, _) = makeController()
        var answers: [ConfirmationAnswer] = []
        controller.ask(ConfirmationPrompt(question: "Push?")) { a, _ in answers.append(a) }

        await emitGesture(provider, nod: true)   // gesture lands first
        controller.answer(.denied)         // click races in behind it
        XCTAssertEqual(answers, [.confirmed])
    }

    // MARK: Feedback

    func testFeedbackFiresOncePerAnswer() async {
        let (controller, provider, feedback) = makeController()
        controller.ask(ConfirmationPrompt(question: "Dock?")) { _, _ in }
        await emitGesture(provider, nod: false)
        XCTAssertEqual(feedback.performed, [.denied])
    }

    func testNoFeedbackWhenCancelled() {
        let (controller, _, feedback) = makeController()
        controller.ask(ConfirmationPrompt(question: "Dock?")) { _, _ in }
        controller.cancel()
        XCTAssertTrue(feedback.performed.isEmpty)
        XCTAssertNil(controller.flash)
    }

    // MARK: Lifecycle

    func testCancelStopsListeningAndClearsPrompt() async {
        let (controller, provider, _) = makeController()
        var answered = false
        controller.ask(ConfirmationPrompt(question: "Dock?")) { _, _ in answered = true }
        controller.cancel()

        XCTAssertNil(controller.prompt)
        XCTAssertFalse(provider.isRunning)
        await emitGesture(provider, nod: true, at: 10)
        XCTAssertFalse(answered)
    }

    func testNewPromptSupersedesUnansweredOne() async {
        let (controller, provider, _) = makeController()
        var first = 0
        var second = 0
        controller.ask(ConfirmationPrompt(question: "First?")) { _, _ in first += 1 }
        controller.ask(ConfirmationPrompt(question: "Second?")) { _, _ in second += 1 }

        XCTAssertEqual(controller.prompt?.question, "Second?")
        await emitGesture(provider, nod: true)
        XCTAssertEqual(first, 0, "the superseded prompt must not be answered")
        XCTAssertEqual(second, 1)
    }

    // MARK: Unavailable hardware

    func testPromptStillWorksWithoutAirPods() {
        let (controller, provider, _) = makeController(available: false)
        var received: ConfirmationAnswer?
        controller.ask(ConfirmationPrompt(question: "Dock?")) { a, _ in received = a }

        XCTAssertFalse(controller.gesturesAvailable)
        XCTAssertFalse(provider.isRunning, "must not start motion updates it cannot use")

        // The prompt is still fully answerable by clicking.
        controller.answer(.confirmed)
        XCTAssertEqual(received, .confirmed)
    }

    func testUnavailableProviderExplainsWhy() {
        let controller = ConfirmationController(
            provider: UnavailableHeadphoneMotionProvider(),
            feedback: RecordingFeedback()
        )
        XCTAssertFalse(controller.gesturesAvailable)
        XCTAssertTrue(controller.gestureStatus.contains("macOS 14"))
    }
}
