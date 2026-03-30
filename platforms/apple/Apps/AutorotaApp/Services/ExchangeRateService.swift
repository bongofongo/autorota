import Foundation
import Observation

@Observable
final class ExchangeRateService {

    /// Rates relative to USD: e.g. ["eur": 0.92, "gbp": 0.79] means 1 USD = 0.92 EUR.
    private(set) var rates: [String: Double] = [:]
    private(set) var lastUpdated: Date?

    private let cacheRatesKey = "exchangeRates"
    private let cacheTimestampKey = "exchangeRatesTimestamp"

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
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR,GBP") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
            let newRates = Dictionary(uniqueKeysWithValues: response.rates.map { ($0.key.lowercased(), $0.value) })
            rates = newRates
            lastUpdated = Date()
            saveCache()
        } catch {
            // Silently fail — use cached or fallback rates.
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
