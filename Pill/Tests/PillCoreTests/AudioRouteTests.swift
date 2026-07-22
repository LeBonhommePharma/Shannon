import XCTest
@testable import PillCore

final class AudioRouteTests: XCTestCase {

    // MARK: Model classification

    func testAirPodsProBeatsBareAirPodsPrefix() {
        // Order matters: "AirPods Pro" contains "AirPods".
        XCTAssertEqual(AirPodsModel.from(deviceName: "LP's AirPods Pro"), .airPodsPro)
        XCTAssertEqual(AirPodsModel.from(deviceName: "AirPods Max"), .airPodsMax)
        XCTAssertEqual(AirPodsModel.from(deviceName: "AirPods"), .airPods)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(AirPodsModel.from(deviceName: "AIRPODS PRO"), .airPodsPro)
        XCTAssertEqual(AirPodsModel.from(deviceName: "airpods max"), .airPodsMax)
    }

    func testBeatsAndUnrelatedDevices() {
        XCTAssertEqual(AirPodsModel.from(deviceName: "Powerbeats Pro"), .beats)
        XCTAssertNil(AirPodsModel.from(deviceName: "MacBook Pro Speakers"))
        XCTAssertNil(AirPodsModel.from(deviceName: "Studio Display"))
    }

    func testSymbolNamesAreDistinct() {
        XCTAssertEqual(AirPodsModel.airPodsPro.symbolName, "airpodspro")
        XCTAssertEqual(AirPodsModel.airPodsMax.symbolName, "airpodsmax")
        XCTAssertEqual(AirPodsModel.unknownBluetooth.symbolName, "headphones")
    }

    // MARK: Route construction

    func testRenamedBluetoothHeadphonesStillCountAsHeadworn() {
        // A user can rename AirPods to anything; a Bluetooth output is still
        // private listening even if we cannot identify the model.
        let route = AudioOutputRoute(deviceName: "Lab Cans", isBluetooth: true)
        XCTAssertEqual(route.model, .unknownBluetooth)
        XCTAssertTrue(route.isHeadworn)
    }

    func testBuiltInSpeakersAreNotHeadworn() {
        let route = AudioOutputRoute(deviceName: "MacBook Pro Speakers", isBluetooth: false)
        XCTAssertNil(route.model)
        XCTAssertFalse(route.isHeadworn)
    }

    func testWiredDeviceNamedAirPodsIsStillClassified() {
        let route = AudioOutputRoute(deviceName: "AirPods Pro", isBluetooth: false)
        XCTAssertEqual(route.model, .airPodsPro)
    }

    // MARK: Transitions

    private func airpods() -> AudioOutputRoute {
        AudioOutputRoute(deviceName: "AirPods Pro", isBluetooth: true)
    }
    private func speakers() -> AudioOutputRoute {
        AudioOutputRoute(deviceName: "MacBook Pro Speakers", isBluetooth: false)
    }

    func testConnectingHeadphones() {
        XCTAssertEqual(
            RouteTransition.between(old: speakers(), new: airpods()),
            .headwornConnected(.airPodsPro)
        )
    }

    func testDisconnectingHeadphones() {
        XCTAssertEqual(
            RouteTransition.between(old: airpods(), new: speakers()),
            .headwornDisconnected(.airPodsPro)
        )
    }

    func testDisconnectingToNoRouteAtAll() {
        XCTAssertEqual(
            RouteTransition.between(old: airpods(), new: nil),
            .headwornDisconnected(.airPodsPro)
        )
    }

    func testSwitchingBetweenTwoHeadwornDevices() {
        let max = AudioOutputRoute(deviceName: "AirPods Max", isBluetooth: true)
        XCTAssertEqual(
            RouteTransition.between(old: airpods(), new: max),
            .headwornConnected(.airPodsMax)
        )
    }

    func testSameRouteIsNoTransition() {
        XCTAssertEqual(RouteTransition.between(old: airpods(), new: airpods()), .none)
        XCTAssertEqual(RouteTransition.between(old: nil, new: nil), .none)
    }

    func testChangingBetweenNonHeadwornOutputs() {
        let display = AudioOutputRoute(deviceName: "Studio Display", isBluetooth: false)
        XCTAssertEqual(
            RouteTransition.between(old: speakers(), new: display),
            .changedOutput("Studio Display")
        )
    }
}

@MainActor
final class AnnouncerTests: XCTestCase {

    private func make() -> (Announcer, RecordingSynthesizer, StubAudioRouteProvider) {
        let synth = RecordingSynthesizer()
        let provider = StubAudioRouteProvider(
            route: AudioOutputRoute(deviceName: "AirPods Pro", isBluetooth: true)
        )
        let announcer = Announcer(synthesizer: synth, routeProvider: provider)
        announcer.start()
        return (announcer, synth, provider)
    }

    func testSpeaksWhenHeadphonesConnected() {
        let (announcer, synth, _) = make()
        announcer.announce("Target 1G9V complete")
        XCTAssertEqual(synth.spoken, ["Target 1G9V complete"])
    }

    func testHoldsWhenHeadphonesDisconnect() {
        let (announcer, synth, provider) = make()
        provider.simulate(AudioOutputRoute(deviceName: "MacBook Pro Speakers", isBluetooth: false))

        announcer.announce("Target 2 complete")
        XCTAssertTrue(announcer.isHeld)
        XCTAssertTrue(synth.spoken.isEmpty, "must not announce to the room")
    }

    func testUrgentItemsSurviveTheGapButRoutineDoesNot() {
        let (announcer, synth, provider) = make()
        provider.simulate(nil)   // AirPods gone

        announcer.announce("target 3 complete", priority: .routine)
        announcer.announce("agent blocked, input needed", priority: .urgent)
        XCTAssertTrue(synth.spoken.isEmpty)

        provider.simulate(AudioOutputRoute(deviceName: "AirPods Pro", isBluetooth: true))
        XCTAssertEqual(synth.spoken, ["agent blocked, input needed"])
    }

    func testDoesNotSpeakThroughBuiltInSpeakersByDefault() {
        let synth = RecordingSynthesizer()
        let provider = StubAudioRouteProvider(
            route: AudioOutputRoute(deviceName: "MacBook Pro Speakers", isBluetooth: false)
        )
        let announcer = Announcer(synthesizer: synth, routeProvider: provider)
        announcer.start()

        announcer.announce("Benchmark finished")
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertTrue(announcer.isHeld)
    }

    func testSpeakerOutputAllowedWhenRequirementRelaxed() {
        let synth = RecordingSynthesizer()
        let provider = StubAudioRouteProvider(
            route: AudioOutputRoute(deviceName: "MacBook Pro Speakers", isBluetooth: false)
        )
        let announcer = Announcer(synthesizer: synth, routeProvider: provider)
        announcer.requireHeadworn = false
        announcer.start()

        announcer.announce("Benchmark finished")
        XCTAssertEqual(synth.spoken, ["Benchmark finished"])
    }

    func testExplicitHoldStopsCurrentSpeech() {
        let (announcer, synth, _) = make()
        announcer.announce("a long announcement")
        announcer.hold()
        XCTAssertTrue(announcer.isHeld)

        announcer.announce("should not be spoken")
        XCTAssertEqual(synth.spoken, ["a long announcement"])
    }
}
