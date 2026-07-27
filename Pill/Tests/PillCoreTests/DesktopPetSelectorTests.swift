import XCTest
@testable import PillCore

/// Pure Settings pet-selector list + normalize/persist path.
final class DesktopPetSelectorTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.shannon.pet.selector.\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.isEmpty
            ? "x" : defaults.dictionaryRepresentation().description)
        defaults = nil
        super.tearDown()
    }

    func testPrettyLabelTitleCasesIds() {
        XCTAssertEqual(DesktopPetSelector.prettyLabel("shannon-hub"), "Shannon Hub")
        XCTAssertEqual(DesktopPetSelector.prettyLabel("bonhomme_cat"), "Bonhomme Cat")
        XCTAssertEqual(DesktopPetSelector.prettyLabel("grok"), "Grok")
    }

    func testOptionsAlwaysIncludeDefaultAndCurrent() {
        let packages = [
            PetPackage.procedural(petId: "firebear", notes: ["test"]),
        ]
        // procedural still has a petId — mark as listed
        let opts = DesktopPetSelector.options(
            packages: packages,
            currentPetId: "mystery-pet",
            defaultPetId: "shannon"
        )
        let ids = Set(opts.map(\.petId))
        XCTAssertTrue(ids.contains("shannon"))
        XCTAssertTrue(ids.contains("mystery-pet"))
        XCTAssertTrue(ids.contains("firebear"))
    }

    func testOptionsPreferPackageDisplayNameFromDiskWhenPresent() {
        // Live ~/.codex/pets/shannon-hub if packaged; else procedural-shaped option.
        let packages = PetPackageResolver.listPetPackages(requireV2: true)
        let opts = DesktopPetSelector.options(
            packages: packages,
            currentPetId: "shannon-hub",
            defaultPetId: "shannon"
        )
        let hub = opts.first { $0.petId == "shannon-hub" }
        XCTAssertNotNil(hub, "shannon-hub must appear once packaged under pets root")
        if let hub, packages.contains(where: { $0.petId == "shannon-hub" && !$0.useProcedural }) {
            XCTAssertEqual(hub.displayName, "Shannon Hub")
            XCTAssertTrue(hub.isInstalled)
            XCTAssertFalse(hub.detail.isEmpty)
        }
    }

    func testOptionsUseDisplayNameWhenPackageListed() {
        // Procedural packages use petId as displayName — still selectable.
        let pkg = PetPackage.procedural(petId: "custom-mascot", notes: ["fixture"])
        let opts = DesktopPetSelector.options(
            packages: [pkg],
            currentPetId: "custom-mascot",
            defaultPetId: "shannon"
        )
        let row = opts.first { $0.petId == "custom-mascot" }
        XCTAssertEqual(row?.displayName, "custom-mascot")
        XCTAssertFalse(row?.isInstalled ?? true)
    }

    func testOptionsSortedByDisplayName() {
        let packages = [
            PetPackage.procedural(petId: "zebra"),
            PetPackage.procedural(petId: "alpha"),
        ]
        let opts = DesktopPetSelector.options(
            packages: packages,
            currentPetId: "shannon",
            defaultPetId: "shannon"
        )
        let names = opts.map(\.displayName)
        XCTAssertEqual(names, names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    func testContainsNormalizedPetId() {
        let opts = [
            DesktopPetOption(petId: "shannon", displayName: "Shannon"),
            DesktopPetOption(petId: "grok", displayName: "Grok"),
        ]
        XCTAssertTrue(DesktopPetSelector.contains(petId: "  Grok  ", in: opts))
        XCTAssertFalse(DesktopPetSelector.contains(petId: "missing", in: opts))
    }

    /// Selecting an id writes preferences and reloads on a fresh store.
    @MainActor
    func testStorePersistsDesktopPetSelection() {
        let store = ShannonPreferencesStore(defaults: defaults)
        store.desktopPetId = "shannon-hub"
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "shannon-hub")
        let store2 = ShannonPreferencesStore(defaults: defaults)
        XCTAssertEqual(store2.desktopPetId, "shannon-hub")
        store2.desktopPetId = "  firebear  "
        XCTAssertEqual(store2.desktopPetId, "firebear")
        XCTAssertEqual(ShannonPreferences.desktopPetId(defaults: defaults), "firebear")
    }

    func testOptionsFromDiskIncludesDefaultAtLeast() {
        // Live machine may have ~/.codex/pets; empty is still ok if default injected.
        let opts = DesktopPetSelector.optionsFromDisk(currentPetId: "shannon")
        XCTAssertFalse(opts.isEmpty)
        XCTAssertTrue(opts.contains { $0.petId == "shannon" })
    }
}
