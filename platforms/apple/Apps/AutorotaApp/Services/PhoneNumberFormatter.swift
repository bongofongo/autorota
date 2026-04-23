import Foundation

/// Supported dialing countries for the phone-entry picker. Each case defines
/// the calling code, trunk-zero convention, NSN (national significant
/// number) length bounds, valid leading digits, and the display grouping
/// rule. `.other` means "manual entry — no formatting/validation".
enum PhoneCountry: String, CaseIterable, Identifiable {
    case uk, us, ca, ie, fr, de, es, it, nl, pt, au, nz, other

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .uk: "🇬🇧"
        case .us: "🇺🇸"
        case .ca: "🇨🇦"
        case .ie: "🇮🇪"
        case .fr: "🇫🇷"
        case .de: "🇩🇪"
        case .es: "🇪🇸"
        case .it: "🇮🇹"
        case .nl: "🇳🇱"
        case .pt: "🇵🇹"
        case .au: "🇦🇺"
        case .nz: "🇳🇿"
        case .other: "🌐"
        }
    }

    var displayName: String {
        switch self {
        case .uk: "United Kingdom"
        case .us: "United States"
        case .ca: "Canada"
        case .ie: "Ireland"
        case .fr: "France"
        case .de: "Germany"
        case .es: "Spain"
        case .it: "Italy"
        case .nl: "Netherlands"
        case .pt: "Portugal"
        case .au: "Australia"
        case .nz: "New Zealand"
        case .other: "Other"
        }
    }

    /// E.164 calling code without the leading `+`. Empty for `.other`.
    var callingCode: String {
        switch self {
        case .uk: "44"
        case .us, .ca: "1"
        case .ie: "353"
        case .fr: "33"
        case .de: "49"
        case .es: "34"
        case .it: "39"
        case .nl: "31"
        case .pt: "351"
        case .au: "61"
        case .nz: "64"
        case .other: ""
        }
    }

    /// Does the country's domestic form use a leading trunk `0`? If yes,
    /// we strip it when building E.164 and auto-strip a stray `0` after
    /// `+CC`.
    var hasTrunkZero: Bool {
        switch self {
        case .uk, .ie, .fr, .de, .nl, .au, .nz: true
        case .us, .ca, .es, .it, .pt, .other: false
        }
    }

    /// Allowed length of the NSN (digits only, no trunk 0 and no +CC).
    var nsnLengthRange: ClosedRange<Int> {
        switch self {
        case .uk: 9...10
        case .us, .ca: 10...10
        case .ie: 7...9
        case .fr: 9...9
        case .de: 6...12
        case .es: 9...9
        case .it: 9...11
        case .nl: 9...9
        case .pt: 9...9
        case .au: 9...9
        case .nz: 8...10
        case .other: 7...15
        }
    }

    /// Valid first digit of the NSN. `nil` = no restriction.
    var validNSNLeadingDigits: Set<Character>? {
        switch self {
        case .uk: ["1", "2", "3", "5", "7", "8", "9"]
        case .us, .ca: ["2", "3", "4", "5", "6", "7", "8", "9"]
        case .fr: ["1", "2", "3", "4", "5", "6", "7", "9"]
        case .ie: ["1", "2", "4", "5", "6", "7", "8", "9"]
        case .es: ["5", "6", "7", "8", "9"]
        case .it: nil
        case .nl: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        case .pt: ["2", "3", "7", "8", "9"]
        case .au: nil
        case .nz: nil
        case .de: nil
        case .other: nil
        }
    }

    /// Placeholder example shown in the text field. Shown without `+CC`
    /// since the country chip already displays the calling code.
    var placeholder: String {
        switch self {
        case .uk: "7400 123456"
        case .us, .ca: "(555) 123-4567"
        case .ie: "87 123 4567"
        case .fr: "6 12 34 56 78"
        case .de: "151 12345678"
        case .es: "612 345 678"
        case .it: "312 345 6789"
        case .nl: "6 12345678"
        case .pt: "912 345 678"
        case .au: "412 345 678"
        case .nz: "21 123 4567"
        case .other: "Phone number"
        }
    }

    /// Short chip label used on the button itself.
    var chipLabel: String {
        callingCode.isEmpty ? "Other" : "+\(callingCode)"
    }

    // MARK: - Formatting

    /// Group a national significant number (digits only, no trunk 0, no
    /// `+CC`) for display. `.other` is untouched.
    func formatNSN(_ nsn: String) -> String {
        guard !nsn.isEmpty else { return "" }
        switch self {
        case .uk:
            return Self.formatGBNSN(nsn)
        case .us, .ca:
            return Self.formatUSNSN(nsn)
        case .fr:
            return Self.splitAt(nsn, [1, 3, 5, 7])
        case .de:
            return Self.splitAt(nsn, [3])
        case .es, .pt, .au, .it:
            return Self.splitAt(nsn, [3, 6])
        case .ie:
            return Self.splitAt(nsn, [2, 5])
        case .nl:
            return Self.splitAt(nsn, [1, 5])
        case .nz:
            return Self.splitAt(nsn, [2, 5])
        case .other:
            return nsn
        }
    }

    // MARK: - Validation

    func isValidNSN(_ nsn: String) -> Bool {
        guard nsnLengthRange.contains(nsn.count) else { return false }
        if let valid = validNSNLeadingDigits, let first = nsn.first {
            guard valid.contains(first) else { return false }
        }
        return true
    }

    // MARK: - Detection

    /// Infer the country from an E.164-like string (leading `+`). Falls back
    /// to `.other` when no match.
    static func detect(from raw: String) -> PhoneCountry {
        let norm = raw.filter { $0.isNumber || $0 == "+" }
        guard norm.hasPrefix("+") else { return .other }
        let digits = String(norm.dropFirst())
        // Try longest calling codes first so `+353` beats `+3`.
        let candidates = PhoneCountry.allCases
            .filter { !$0.callingCode.isEmpty }
            .sorted { $0.callingCode.count > $1.callingCode.count }
        for c in candidates where digits.hasPrefix(c.callingCode) {
            return c
        }
        return .other
    }

    /// Map an ISO region code (e.g. "GB") to a supported country, or
    /// `.other` when unsupported.
    init(regionCode: String) {
        switch regionCode.uppercased() {
        case "GB": self = .uk
        case "US": self = .us
        case "CA": self = .ca
        case "IE": self = .ie
        case "FR": self = .fr
        case "DE": self = .de
        case "ES": self = .es
        case "IT": self = .it
        case "NL": self = .nl
        case "PT": self = .pt
        case "AU": self = .au
        case "NZ": self = .nz
        default: self = .other
        }
    }

    // MARK: - Shared grouping helpers

    fileprivate static func splitAt(_ s: String, _ indices: [Int]) -> String {
        let cuts = Set(indices)
        var out = ""
        for (i, ch) in s.enumerated() {
            if cuts.contains(i) { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// GB NSN grouping per Ofcom conventions — picks layout by prefix.
    fileprivate static func formatGBNSN(_ nsn: String) -> String {
        guard !nsn.isEmpty else { return "" }
        let chars = Array(nsn)
        if chars[0] == "7" { return splitAt(nsn, [4]) }
        if chars[0] == "2" { return splitAt(nsn, [2, 6]) }
        if nsn.count >= 3, Self.gb3DigitAreaCodes.contains(String(chars.prefix(3))) {
            return splitAt(nsn, [3, 6])
        }
        if chars[0] == "1" { return splitAt(nsn, [4]) }
        if chars[0] == "3" || chars[0] == "8" || chars[0] == "9" {
            return splitAt(nsn, [3, 6])
        }
        if chars[0] == "5" { return splitAt(nsn, [3]) }
        return splitAt(nsn, [3, 6])
    }

    /// US/CA NSN grouping: `(XXX) XXX-XXXX`.
    fileprivate static func formatUSNSN(_ nsn: String) -> String {
        let n = nsn.count
        if n == 0 { return "" }
        if n <= 3 { return "(\(nsn)" }
        if n <= 6 {
            let a = nsn.prefix(3)
            let b = nsn.dropFirst(3)
            return "(\(a)) \(b)"
        }
        let a = nsn.prefix(3)
        let b = nsn.dropFirst(3).prefix(3)
        let c = nsn.dropFirst(6).prefix(4)
        return "(\(a)) \(b)-\(c)"
    }

    private static let gb3DigitAreaCodes: Set<String> = [
        "113", "114", "115", "116", "117", "118",
        "121", "131", "141", "151", "161", "191"
    ]
}

/// Lightweight phone-number helper. Holds a `PhoneCountry` and provides:
/// - `format(_:)` for display including trunk 0 / parens (legacy API —
///   infers from whether input has `+`).
/// - `formatForField(_:)` for the edit field: NSN-only grouping when a
///   country is selected; raw text for `.other`.
/// - `normalizeForStorage(_:)` to produce E.164 `+<CC><NSN>` when possible.
/// - `isValid(_:)` per selected country (or generic length for `.other`).
struct PhoneNumberFormatter {

    let country: PhoneCountry

    init(country: PhoneCountry) { self.country = country }

    init(regionCode: String? = nil) {
        let code = (regionCode ?? Locale.current.region?.identifier ?? "").uppercased()
        self.country = PhoneCountry(regionCode: code)
    }

    // MARK: - Normalize

    /// Strip input to digits, preserving a single leading `+`.
    func normalize(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch == "+" && out.isEmpty {
                out.append("+")
            } else if ch.isNumber {
                out.append(ch)
            }
        }
        return out
    }

    /// Extract the NSN from raw text. Strips `+<CC>`, then trunk 0 (when
    /// the country uses one). For `.other`, returns digits only.
    func extractNSN(_ raw: String) -> String {
        let norm = normalize(raw)
        if case .other = country {
            return norm.hasPrefix("+") ? String(norm.dropFirst()) : norm
        }
        let cc = country.callingCode
        if norm.hasPrefix("+\(cc)") {
            var rest = String(norm.dropFirst(cc.count + 1))
            if country.hasTrunkZero, rest.hasPrefix("0") { rest = String(rest.dropFirst()) }
            return rest
        }
        if norm.hasPrefix("+") {
            // Different calling code — leave digits as-is.
            return String(norm.dropFirst())
        }
        if country.hasTrunkZero, norm.hasPrefix("0") {
            return String(norm.dropFirst())
        }
        return norm
    }

    // MARK: - Format for display

    /// Legacy domestic/international display. Used by read-only cells and
    /// older call sites. International when input starts with `+`, national
    /// otherwise.
    func format(_ raw: String) -> String {
        let norm = normalize(raw)
        let hasPlus = norm.hasPrefix("+")
        let digits = hasPlus ? String(norm.dropFirst()) : norm

        if hasPlus {
            // Try this formatter's country first, else any known country.
            let detected = PhoneCountry.detect(from: norm)
            let effective = detected == .other ? country : detected
            if effective != .other, digits.hasPrefix(effective.callingCode) {
                var nsn = String(digits.dropFirst(effective.callingCode.count))
                if effective.hasTrunkZero, nsn.hasPrefix("0") { nsn = String(nsn.dropFirst()) }
                let grouped = effective.formatNSN(nsn)
                return grouped.isEmpty
                    ? "+\(effective.callingCode)"
                    : "+\(effective.callingCode) \(grouped)"
            }
            // Generic international fallback.
            return "+" + Self.genericGroup(digits)
        }

        if case .other = country { return norm }

        if country.hasTrunkZero {
            guard digits.hasPrefix("0") else { return country.formatNSN(digits) }
            let nsn = String(digits.dropFirst())
            let grouped = country.formatNSN(nsn)
            return grouped.isEmpty ? "0" : "0\(grouped)"
        }
        return country.formatNSN(digits)
    }

    /// Edit-field display. NSN-only grouping when a country is selected;
    /// raw text for `.other`.
    func formatForField(_ raw: String) -> String {
        if case .other = country { return normalize(raw) }
        let nsn = extractNSN(raw)
        return country.formatNSN(nsn)
    }

    // MARK: - Storage

    /// E.164 form when country is known: `+<CC><NSN>`. For `.other`, stores
    /// the normalized input as-is. Partial/invalid NSN lengths keep the
    /// raw normalized input so we don't corrupt mid-typing state.
    func normalizeForStorage(_ raw: String) -> String {
        let norm = normalize(raw)
        if case .other = country { return norm }

        let cc = country.callingCode
        if norm.hasPrefix("+\(cc)") {
            var rest = String(norm.dropFirst(cc.count + 1))
            if country.hasTrunkZero, rest.hasPrefix("0") { rest = String(rest.dropFirst()) }
            return "+\(cc)\(rest)"
        }
        if norm.hasPrefix("+") { return norm }

        var nsn = norm
        if country.hasTrunkZero, nsn.hasPrefix("0") { nsn = String(nsn.dropFirst()) }
        guard country.nsnLengthRange.contains(nsn.count) else { return norm }
        return "+\(cc)\(nsn)"
    }

    // MARK: - Validate

    /// Validity against the selected country's rules (or generic 7–15
    /// digit length for `.other`).
    func isValid(_ raw: String) -> Bool {
        if case .other = country {
            let count = normalize(raw).filter { $0.isNumber }.count
            return (7...15).contains(count)
        }
        let nsn = extractNSN(raw)
        return country.isValidNSN(nsn)
    }

    // MARK: - Generic grouping (used by `.other` international display)

    private static func genericGroup(_ digits: String) -> String {
        let n = digits.count
        switch n {
        case 0: return ""
        case 1...3: return digits
        case 4...6: return PhoneCountry.splitAt(digits, [3])
        case 7: return PhoneCountry.splitAt(digits, [3])
        case 8: return PhoneCountry.splitAt(digits, [2, 4, 6])
        case 9, 10: return PhoneCountry.splitAt(digits, [3, 6])
        case 11: return PhoneCountry.splitAt(digits, [3, 7])
        case 12: return PhoneCountry.splitAt(digits, [4, 8])
        default: return PhoneCountry.splitAt(digits, [3, 6, 9, 12])
        }
    }
}
