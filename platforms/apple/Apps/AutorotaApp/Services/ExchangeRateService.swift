import Foundation
import Observation
import os

@Observable
final class ExchangeRateService {

    /// Rates relative to USD: e.g. ["eur": 0.92, "gbp": 0.79] means 1 USD = 0.92 EUR.
    private(set) var rates: [String: Double] = [:]
    private(set) var lastUpdated: Date?
    /// Last fetch error, surfaced for UI so the user can be warned when
    /// rates may be stale. Cleared on the next successful fetch.
    private(set) var lastFetchError: String?

    /// True when cached rates are older than `staleAfter` (or have never
    /// been fetched). Wage conversions still work using whatever's cached
    /// — this just gates a UI warning banner.
    var ratesAreStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > Self.staleAfter
    }

    private let cacheRatesKey = "exchangeRates"
    private let cacheTimestampKey = "exchangeRatesTimestamp"

    /// Frankfurter is a free, no-key forex API. URL is a constant rather
    /// than a literal so it shows up at the top of the file for review.
    private static let ratesURL = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR,GBP")!
    /// Rates older than 7 days flip `ratesAreStale` to true so the UI
    /// banner can surface "rates may be outdated".
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private let logger = Logger(subsystem: "com.toadmountain.autorota", category: "exchange-rate")

    /// Fallback rates used when no cached or fetched data is available.
    private static let fallbackRates: [String: Double] = [
        "eur": 0.92,
        "gbp": 0.79,
    ]

    init() {
        loadCached()
    }

    // MARK: - Conversion

    /// Convert an amount from one currency to another.
    /// Currency codes should be lowercase: "usd", "eur", "gbp".
    func convert(_ amount: Float, from: String, to: String) -> Float {
        if from == to { return amount }
        let fromRate = rate(for: from)
        let toRate = rate(for: to)
        guard fromRate > 0 else { return amount }
        return amount * Float(toRate / fromRate)
    }

    /// The symbol for a currency code (e.g. "usd" -> "$").
    func symbol(for code: String) -> String {
        (AppCurrency(rawValue: code) ?? .usd).symbol
    }

    // MARK: - Fetching

    func fetchRates() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.ratesURL)
            let response = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
            let newRates = Dictionary(uniqueKeysWithValues: response.rates.map { ($0.key.lowercased(), $0.value) })
            rates = newRates
            lastUpdated = Date()
            lastFetchError = nil
            saveCache()
        } catch {
            // Don't blank out cached rates; surface the failure so the UI can
            // banner "rates may be outdated" alongside whatever's cached.
            lastFetchError = error.localizedDescription
            logger.warning("Failed to fetch exchange rates: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func rate(for currency: String) -> Double {
        if currency == "usd" { return 1.0 }
        return rates[currency] ?? Self.fallbackRates[currency] ?? 1.0
    }

    private func loadCached() {
        if let data = UserDefaults.standard.data(forKey: cacheRatesKey),
           let cached = try? JSONDecoder().decode([String: Double].self, from: data) {
            rates = cached
        }
        if let ts = UserDefaults.standard.object(forKey: cacheTimestampKey) as? Date {
            lastUpdated = ts
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(rates) {
            UserDefaults.standard.set(data, forKey: cacheRatesKey)
        }
        UserDefaults.standard.set(lastUpdated, forKey: cacheTimestampKey)
    }
}

// MARK: - API response

private struct FrankfurterResponse: Decodable {
    let rates: [String: Double]
}
