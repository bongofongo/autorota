import Foundation
import Testing
@testable import AutorotaApp

struct PricingCatalogTests {

    // Local Manager is currently free for early users, so the display price is a
    // localized "Free" label regardless of region.

    @Test
    func freeForUnitedKingdom() {
        let locale = Locale(identifier: "en_GB")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "Free")
    }

    @Test
    func freeForUnitedStates() {
        let locale = Locale(identifier: "en_US")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "Free")
    }

    @Test
    func freeForGermany() {
        let locale = Locale(identifier: "de_DE")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "Free")
    }

    @Test
    func localManagerIsFree() {
        #expect(PricingCatalog.isFree(for: .localManager))
    }

    @Test
    func unavailableTiersReturnEmpty() {
        let locale = Locale(identifier: "en_US")
        #expect(PricingCatalog.displayPrice(for: .employee, locale: locale) == "")
        #expect(PricingCatalog.displayPrice(for: .saas, locale: locale) == "")
    }
}
