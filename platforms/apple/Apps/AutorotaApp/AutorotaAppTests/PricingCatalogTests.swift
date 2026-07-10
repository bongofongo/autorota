import Foundation
import Testing
@testable import AutorotaApp

struct PricingCatalogTests {

    @Test
    func gbpForUnitedKingdom() {
        let locale = Locale(identifier: "en_GB")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "£3.99")
    }

    @Test
    func usdAsFallback() {
        let locale = Locale(identifier: "en_US")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "$3.99")
    }

    @Test
    func usdForGermany() {
        let locale = Locale(identifier: "de_DE")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "$3.99")
    }

    @Test
    func unknownRegionFallsBackToUSD() {
        let locale = Locale(identifier: "en_NZ")
        #expect(PricingCatalog.displayPrice(for: .localManager, locale: locale) == "$3.99")
    }

    @Test
    func unavailableTiersReturnEmpty() {
        let locale = Locale(identifier: "en_US")
        #expect(PricingCatalog.displayPrice(for: .employee, locale: locale) == "")
        #expect(PricingCatalog.displayPrice(for: .saas, locale: locale) == "")
    }
}
