import Foundation
import Testing
@testable import AutorotaApp

@Suite("PhoneNumberFormatter — GB")
struct PhoneNumberFormatterGBTests {

    private let gb = PhoneNumberFormatter(regionCode: "GB")

    // MARK: - Domestic formatting

    @Test func mobileDomesticGroups5Plus6() {
        #expect(gb.format("07400123456") == "07400 123456")
        #expect(gb.format("07400 123456") == "07400 123456")
        #expect(gb.format("07400-123-456") == "07400 123456")
    }

    @Test func londonThreeFourFour() {
        #expect(gb.format("02079460018") == "020 7946 0018")
        #expect(gb.format("020 7946 0018") == "020 7946 0018")
    }

    @Test func birminghamFourThreeFour() {
        // 0121 uses xxx xxx xxxx inside the NSN: displays `0121 234 5678`.
        #expect(gb.format("01212345678") == "0121 234 5678")
    }

    @Test func leedsFourThreeFour() {
        // 0113 is a 3-digit-area-code NSN (113).
        #expect(gb.format("01134960123") == "0113 496 0123")
    }

    @Test func fourDigitAreaCode() {
        // 01234 (Bedford) groups as 01xxx xxxxxx.
        #expect(gb.format("01234567890") == "01234 567890")
    }

    @Test func freephone0800() {
        #expect(gb.format("08001234567") == "0800 123 4567")
    }

    @Test func nonGeographic03() {
        #expect(gb.format("03451234567") == "0345 123 4567")
    }

    // MARK: - International formatting

    @Test func internationalMobile() {
        #expect(gb.format("+447400123456") == "+44 7400 123456")
        #expect(gb.format("+44 7400 123456") == "+44 7400 123456")
    }

    @Test func internationalLondon() {
        #expect(gb.format("+442079460018") == "+44 20 7946 0018")
    }

    @Test func internationalBirmingham() {
        #expect(gb.format("+441212345678") == "+44 121 234 5678")
    }

    /// Classic "+44 (0) 7..." copy-paste mistake must strip the trunk 0.
    @Test func stripsTrunkZeroAfterPlus44() {
        #expect(gb.format("+44 (0) 7400 123456") == "+44 7400 123456")
        #expect(gb.format("+4407400123456") == "+44 7400 123456")
        #expect(gb.format("+44 0 20 7946 0018") == "+44 20 7946 0018")
    }

    // MARK: - Storage normalization

    @Test func domesticConvertsToE164() {
        #expect(gb.normalizeForStorage("07400 123456") == "+447400123456")
        #expect(gb.normalizeForStorage("020 7946 0018") == "+442079460018")
        #expect(gb.normalizeForStorage("0121 234 5678") == "+441212345678")
    }

    @Test func internationalStaysE164() {
        #expect(gb.normalizeForStorage("+44 7400 123456") == "+447400123456")
    }

    @Test func plus44TrunkZeroStrippedOnStorage() {
        #expect(gb.normalizeForStorage("+44 (0) 7400 123456") == "+447400123456")
        #expect(gb.normalizeForStorage("+4407400123456") == "+447400123456")
    }

    @Test func partialDomesticStaysUnconverted() {
        // Incomplete entry (mid-typing) must not get forced to E.164.
        #expect(gb.normalizeForStorage("0740") == "0740")
    }

    // MARK: - Validation

    @Test func validMobile() {
        #expect(gb.isValid("07400 123456"))
        #expect(gb.isValid("+44 7400 123456"))
        #expect(gb.isValid("+44 (0) 7400 123456"))
    }

    @Test func validLandlineLondon() {
        #expect(gb.isValid("020 7946 0018"))
        #expect(gb.isValid("+44 20 7946 0018"))
    }

    @Test func validFreephone() {
        #expect(gb.isValid("0800 123 4567"))
    }

    @Test func invalidTooShort() {
        #expect(!gb.isValid("0740 123"))
        #expect(!gb.isValid("+44 7400"))
    }

    @Test func invalidTooLong() {
        #expect(!gb.isValid("07400 123456 789"))
        #expect(!gb.isValid("+44 7400 123456 789"))
    }

    @Test func invalidLeadingDigit() {
        // NSN starting with 0, 4, or 6 is not allocated.
        #expect(!gb.isValid("04400 123456"))
        #expect(!gb.isValid("+44 4400 123456"))
        #expect(!gb.isValid("+44 6400 123456"))
    }

    // MARK: - AYTF stability

    @Test func progressiveTypingMobile() {
        let expected = [
            "0", "07", "074", "0740", "07400",
            "07400 1", "07400 12", "07400 123",
            "07400 1234", "07400 12345", "07400 123456"
        ]
        for (i, out) in expected.enumerated() {
            let digits = String("07400123456".prefix(i + 1))
            #expect(gb.format(digits) == out, "step \(i) input=\(digits)")
        }
    }

    @Test func progressiveTypingInternationalMobile() {
        let expected = [
            "+", "+4", "+44",
            "+44 7", "+44 74", "+44 740", "+44 7400",
            "+44 7400 1", "+44 7400 12", "+44 7400 123",
            "+44 7400 1234", "+44 7400 12345", "+44 7400 123456"
        ]
        let full = "+447400123456"
        for (i, out) in expected.enumerated() {
            let prefix = String(full.prefix(i + 1))
            #expect(gb.format(prefix) == out, "step \(i) input=\(prefix)")
        }
    }
}

@Suite("PhoneNumberFormatter — US & generic")
struct PhoneNumberFormatterUSTests {

    private let us = PhoneNumberFormatter(regionCode: "US")

    @Test func usNationalParens() {
        #expect(us.format("5551234567") == "(555) 123-4567")
    }

    @Test func usInternational() {
        // Read-only international display uses the NSN grouping for the
        // detected country — US keeps parens.
        #expect(us.format("+15551234567") == "+1 (555) 123-4567")
    }

    @Test func usDoesNotForceGBConversion() {
        // Domestic `0...` outside GB region is preserved (no +44 prepend).
        #expect(us.normalizeForStorage("07400 123456") == "07400123456")
    }
}

@Suite("PhoneCountry — detection & country-aware APIs")
struct PhoneCountryTests {

    @Test func detectFromE164Prefixes() {
        #expect(PhoneCountry.detect(from: "+447400123456") == .uk)
        #expect(PhoneCountry.detect(from: "+15551234567") == .us)
        #expect(PhoneCountry.detect(from: "+33612345678") == .fr)
        #expect(PhoneCountry.detect(from: "+353871234567") == .ie)
        #expect(PhoneCountry.detect(from: "+4915112345678") == .de)
        #expect(PhoneCountry.detect(from: "+34612345678") == .es)
        #expect(PhoneCountry.detect(from: "+39312345678") == .it)
        #expect(PhoneCountry.detect(from: "+31612345678") == .nl)
        #expect(PhoneCountry.detect(from: "+351912345678") == .pt)
        #expect(PhoneCountry.detect(from: "+61412345678") == .au)
        #expect(PhoneCountry.detect(from: "+64211234567") == .nz)
    }

    @Test func detectPrefersLongestCallingCode() {
        // `+353` must beat `+3` / `+35` — tests longest-prefix-first ordering.
        #expect(PhoneCountry.detect(from: "+353871234567") == .ie)
    }

    @Test func detectFallsBackToOther() {
        #expect(PhoneCountry.detect(from: "07400123456") == .other)
        #expect(PhoneCountry.detect(from: "+9991234567") == .other)
    }

    @Test func ukFieldNSNOnly() {
        let f = PhoneNumberFormatter(country: .uk)
        // User typed trunk 0 domestically — field strips it since chip
        // already shows +44.
        #expect(f.formatForField("07400123456") == "7400 123456")
        #expect(f.formatForField("7400123456") == "7400 123456")
        #expect(f.formatForField("+447400123456") == "7400 123456")
    }

    @Test func ukStorageEveryInputShape() {
        let f = PhoneNumberFormatter(country: .uk)
        #expect(f.normalizeForStorage("07400 123456") == "+447400123456")
        #expect(f.normalizeForStorage("7400123456") == "+447400123456")
        #expect(f.normalizeForStorage("+44 7400 123456") == "+447400123456")
        #expect(f.normalizeForStorage("+44 (0) 7400 123456") == "+447400123456")
    }

    @Test func usFieldAndStorage() {
        let f = PhoneNumberFormatter(country: .us)
        #expect(f.formatForField("5551234567") == "(555) 123-4567")
        #expect(f.formatForField("+15551234567") == "(555) 123-4567")
        #expect(f.normalizeForStorage("(555) 123-4567") == "+15551234567")
        #expect(f.normalizeForStorage("+15551234567") == "+15551234567")
    }

    @Test func frenchGrouping() {
        let f = PhoneNumberFormatter(country: .fr)
        #expect(f.formatForField("612345678") == "6 12 34 56 78")
        #expect(f.formatForField("0612345678") == "6 12 34 56 78")
        #expect(f.formatForField("+33612345678") == "6 12 34 56 78")
        #expect(f.normalizeForStorage("0612345678") == "+33612345678")
        #expect(f.isValid("0612345678"))
        #expect(!f.isValid("061234567"))
    }

    @Test func spanishNineDigits() {
        let f = PhoneNumberFormatter(country: .es)
        #expect(f.formatForField("612345678") == "612 345 678")
        #expect(f.normalizeForStorage("612 345 678") == "+34612345678")
        #expect(f.isValid("612345678"))
        #expect(!f.isValid("12345678"))
    }

    @Test func irishMobile() {
        let f = PhoneNumberFormatter(country: .ie)
        #expect(f.formatForField("871234567") == "87 123 4567")
        #expect(f.formatForField("0871234567") == "87 123 4567")
        #expect(f.normalizeForStorage("087 123 4567") == "+353871234567")
    }

    @Test func dutchMobile() {
        let f = PhoneNumberFormatter(country: .nl)
        #expect(f.formatForField("612345678") == "6 1234 5678")
        #expect(f.formatForField("0612345678") == "6 1234 5678")
        #expect(f.normalizeForStorage("06 12345678") == "+31612345678")
    }

    @Test func australianMobile() {
        let f = PhoneNumberFormatter(country: .au)
        #expect(f.formatForField("412345678") == "412 345 678")
        #expect(f.formatForField("0412345678") == "412 345 678")
        #expect(f.normalizeForStorage("0412 345 678") == "+61412345678")
    }

    @Test func otherModeIsPassThrough() {
        let f = PhoneNumberFormatter(country: .other)
        #expect(f.formatForField("anything 12-34") == "1234")
        #expect(f.formatForField("+1 555-0100") == "+15550100")
        #expect(f.normalizeForStorage("+44 0 7400 123456") == "+4407400123456")
        #expect(f.isValid("1234567"))
        #expect(!f.isValid("123"))
        #expect(!f.isValid("1234567890123456"))
    }

    @Test func invalidStorageStaysRawWhenPartialNSN() {
        // Mid-typing a UK number shouldn't produce a bogus +44<short>.
        let f = PhoneNumberFormatter(country: .uk)
        #expect(f.normalizeForStorage("0740") == "0740")
    }

    @Test func switchingCountryPreservesNSN() {
        // Emulate the UI's country-switch path: extract NSN from one
        // country's view then render under another.
        let fromUK = PhoneNumberFormatter(country: .uk)
        let nsn = fromUK.extractNSN("07400 123456")
        #expect(nsn == "7400123456")
        let toFR = PhoneNumberFormatter(country: .fr)
        // FR splits at [1,3,5,7]; 10-digit NSN yields 5 groups.
        #expect(toFR.formatForField(nsn) == "7 40 01 23 456")
        // A 10-digit input fails FR validation (FR expects 9 digits).
        #expect(!toFR.isValid(nsn))
    }
}
