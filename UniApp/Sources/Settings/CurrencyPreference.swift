import Foundation

/// A fiat currency the user can pick to display token prices in.
///
/// Single source of truth for the supported fiats. Stored under
/// `@AppStorage("currencyPreference")` (ISO-4217 code, e.g. `USD`).
/// Default is `USD`. The price service uses this when fetching from Coinbase.
///
/// Coverage: every actively-traded national fiat currency Coinbase supports
/// via `/v2/exchange-rates`. For the handful Coinbase does not return a rate
/// for, `CoinbasePriceService` returns `nil` and the UI renders
/// "Price unavailable" gracefully — never a crash.
struct SupportedCurrency: Identifiable, Hashable, Sendable {
    /// ISO-4217 code (`USD`, `EUR`, `JPY`, …).
    let code: String
    /// Currency symbol (`$`, `€`, `¥`, …).
    let symbol: String
    /// English display name. (See `TODO.md` T-020 for the planned
    /// switch to `Locale.localizedCurrencyName(forCurrencyCode:)` so the
    /// picker renders names in the user's selected language.)
    let englishName: String

    var id: String { code }
}

enum CurrencyPreference {
    /// `@AppStorage` key.
    static let storageKey = "currencyPreference"
    /// Hard fallback fiat when the device's region can't be resolved to a
    /// supported currency (or `bootstrapIfNeeded()` hasn't run yet). Fresh
    /// installs typically get the device-region currency via
    /// `bootstrapIfNeeded()`; this constant only fires if `Locale.current`
    /// returns nothing useful or returns a currency outside `all`.
    static let defaultCode = "USD"

    /// Resolve the device's natural fiat from `Locale.current` and verify
    /// it's in `SupportedCurrency.all`. Falls back to `defaultCode` (USD)
    /// when the locale doesn't supply a currency or supplies one we don't
    /// support — silent fallback per Rule #2 §A.7 (the user gets a
    /// best-effort default and can change it in Settings).
    static func defaultForCurrentRegion() -> String {
        let candidate = Locale.current.currency?.identifier
            ?? Locale.current.region.flatMap { Locale(identifier: $0.identifier).currency?.identifier }
        if let candidate, all.contains(where: { $0.code == candidate }) {
            return candidate
        }
        return defaultCode
    }

    /// On first launch, seed `UserDefaults[storageKey]` with the device's
    /// natural fiat so the `@AppStorage("currencyPreference")` readers in
    /// `SettingsView` / `CurrencyPickerView` / `MnemonicImport` resolve to
    /// the right currency immediately. Idempotent — subsequent launches
    /// (or anything after the user picks a currency) skip the write.
    /// Call once from `UniAppApp.init()` before the WindowGroup renders.
    static func bootstrapIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: storageKey) == nil else { return }
        defaults.set(defaultForCurrentRegion(), forKey: storageKey)
    }

    /// ISO-4217 fiats Coinbase exposes via `/v2/exchange-rates`. Order
    /// chosen for picker UX: USD/EUR/GBP/JPY/CNY/INR first (most-used
    /// globally), then alphabetical by code. Symbols and names verified
    /// against ISO 4217 and Apple's `Locale.currencySymbol` references.
    static let all: [SupportedCurrency] = [
        // Most-used globally (pinned to the top of the picker)
        .init(code: "USD", symbol: "$",   englishName: "US Dollar"),
        .init(code: "EUR", symbol: "€",   englishName: "Euro"),
        .init(code: "GBP", symbol: "£",   englishName: "British Pound"),
        .init(code: "JPY", symbol: "¥",   englishName: "Japanese Yen"),
        .init(code: "CNY", symbol: "¥",   englishName: "Chinese Yuan"),
        .init(code: "INR", symbol: "₹",   englishName: "Indian Rupee"),

        // Alphabetical by ISO code
        .init(code: "AED", symbol: "د.إ", englishName: "UAE Dirham"),
        .init(code: "AFN", symbol: "؋",   englishName: "Afghan Afghani"),
        .init(code: "ALL", symbol: "L",   englishName: "Albanian Lek"),
        .init(code: "AMD", symbol: "֏",   englishName: "Armenian Dram"),
        .init(code: "ANG", symbol: "ƒ",   englishName: "Netherlands Antillean Guilder"),
        .init(code: "AOA", symbol: "Kz",  englishName: "Angolan Kwanza"),
        .init(code: "ARS", symbol: "$",   englishName: "Argentine Peso"),
        .init(code: "AUD", symbol: "A$",  englishName: "Australian Dollar"),
        .init(code: "AWG", symbol: "ƒ",   englishName: "Aruban Florin"),
        .init(code: "AZN", symbol: "₼",   englishName: "Azerbaijani Manat"),
        .init(code: "BAM", symbol: "KM",  englishName: "Bosnia-Herzegovina Convertible Mark"),
        .init(code: "BBD", symbol: "Bds$", englishName: "Barbadian Dollar"),
        .init(code: "BDT", symbol: "৳",   englishName: "Bangladeshi Taka"),
        .init(code: "BGN", symbol: "лв",  englishName: "Bulgarian Lev"),
        .init(code: "BHD", symbol: ".د.ب", englishName: "Bahraini Dinar"),
        .init(code: "BIF", symbol: "FBu", englishName: "Burundian Franc"),
        .init(code: "BMD", symbol: "BD$", englishName: "Bermudian Dollar"),
        .init(code: "BND", symbol: "B$",  englishName: "Brunei Dollar"),
        .init(code: "BOB", symbol: "Bs.", englishName: "Bolivian Boliviano"),
        .init(code: "BRL", symbol: "R$",  englishName: "Brazilian Real"),
        .init(code: "BSD", symbol: "B$",  englishName: "Bahamian Dollar"),
        .init(code: "BTN", symbol: "Nu.", englishName: "Bhutanese Ngultrum"),
        .init(code: "BWP", symbol: "P",   englishName: "Botswanan Pula"),
        .init(code: "BYN", symbol: "Br",  englishName: "Belarusian Ruble"),
        .init(code: "BZD", symbol: "BZ$", englishName: "Belize Dollar"),
        .init(code: "CAD", symbol: "C$",  englishName: "Canadian Dollar"),
        .init(code: "CDF", symbol: "FC",  englishName: "Congolese Franc"),
        .init(code: "CHF", symbol: "CHF", englishName: "Swiss Franc"),
        .init(code: "CLP", symbol: "$",   englishName: "Chilean Peso"),
        .init(code: "COP", symbol: "$",   englishName: "Colombian Peso"),
        .init(code: "CRC", symbol: "₡",   englishName: "Costa Rican Colón"),
        .init(code: "CVE", symbol: "$",   englishName: "Cape Verdean Escudo"),
        .init(code: "CZK", symbol: "Kč",  englishName: "Czech Koruna"),
        .init(code: "DJF", symbol: "Fdj", englishName: "Djiboutian Franc"),
        .init(code: "DKK", symbol: "kr",  englishName: "Danish Krone"),
        .init(code: "DOP", symbol: "RD$", englishName: "Dominican Peso"),
        .init(code: "DZD", symbol: "د.ج", englishName: "Algerian Dinar"),
        .init(code: "EGP", symbol: "ج.م", englishName: "Egyptian Pound"),
        .init(code: "ETB", symbol: "Br",  englishName: "Ethiopian Birr"),
        .init(code: "FJD", symbol: "FJ$", englishName: "Fijian Dollar"),
        .init(code: "GEL", symbol: "₾",   englishName: "Georgian Lari"),
        .init(code: "GHS", symbol: "₵",   englishName: "Ghanaian Cedi"),
        .init(code: "GMD", symbol: "D",   englishName: "Gambian Dalasi"),
        .init(code: "GNF", symbol: "FG",  englishName: "Guinean Franc"),
        .init(code: "GTQ", symbol: "Q",   englishName: "Guatemalan Quetzal"),
        .init(code: "GYD", symbol: "G$",  englishName: "Guyanese Dollar"),
        .init(code: "HKD", symbol: "HK$", englishName: "Hong Kong Dollar"),
        .init(code: "HNL", symbol: "L",   englishName: "Honduran Lempira"),
        .init(code: "HUF", symbol: "Ft",  englishName: "Hungarian Forint"),
        .init(code: "IDR", symbol: "Rp",  englishName: "Indonesian Rupiah"),
        .init(code: "ILS", symbol: "₪",   englishName: "Israeli New Shekel"),
        .init(code: "IQD", symbol: "ع.د", englishName: "Iraqi Dinar"),
        .init(code: "ISK", symbol: "kr",  englishName: "Icelandic Króna"),
        .init(code: "JMD", symbol: "J$",  englishName: "Jamaican Dollar"),
        .init(code: "JOD", symbol: "د.ا", englishName: "Jordanian Dinar"),
        .init(code: "KES", symbol: "KSh", englishName: "Kenyan Shilling"),
        .init(code: "KGS", symbol: "с",   englishName: "Kyrgyzstani Som"),
        .init(code: "KHR", symbol: "៛",   englishName: "Cambodian Riel"),
        .init(code: "KMF", symbol: "CF",  englishName: "Comorian Franc"),
        .init(code: "KRW", symbol: "₩",   englishName: "South Korean Won"),
        .init(code: "KWD", symbol: "د.ك", englishName: "Kuwaiti Dinar"),
        .init(code: "KYD", symbol: "CI$", englishName: "Cayman Islands Dollar"),
        .init(code: "KZT", symbol: "₸",   englishName: "Kazakhstani Tenge"),
        .init(code: "LAK", symbol: "₭",   englishName: "Lao Kip"),
        .init(code: "LBP", symbol: "ل.ل", englishName: "Lebanese Pound"),
        .init(code: "LKR", symbol: "Rs",  englishName: "Sri Lankan Rupee"),
        .init(code: "LRD", symbol: "L$",  englishName: "Liberian Dollar"),
        .init(code: "LSL", symbol: "L",   englishName: "Lesotho Loti"),
        .init(code: "MAD", symbol: "د.م.", englishName: "Moroccan Dirham"),
        .init(code: "MDL", symbol: "L",   englishName: "Moldovan Leu"),
        .init(code: "MGA", symbol: "Ar",  englishName: "Malagasy Ariary"),
        .init(code: "MKD", symbol: "ден", englishName: "Macedonian Denar"),
        .init(code: "MMK", symbol: "K",   englishName: "Myanmar Kyat"),
        .init(code: "MNT", symbol: "₮",   englishName: "Mongolian Tögrög"),
        .init(code: "MOP", symbol: "MOP$", englishName: "Macanese Pataca"),
        .init(code: "MUR", symbol: "₨",   englishName: "Mauritian Rupee"),
        .init(code: "MVR", symbol: "Rf",  englishName: "Maldivian Rufiyaa"),
        .init(code: "MWK", symbol: "MK",  englishName: "Malawian Kwacha"),
        .init(code: "MXN", symbol: "MX$", englishName: "Mexican Peso"),
        .init(code: "MYR", symbol: "RM",  englishName: "Malaysian Ringgit"),
        .init(code: "MZN", symbol: "MT",  englishName: "Mozambican Metical"),
        .init(code: "NAD", symbol: "N$",  englishName: "Namibian Dollar"),
        .init(code: "NGN", symbol: "₦",   englishName: "Nigerian Naira"),
        .init(code: "NIO", symbol: "C$",  englishName: "Nicaraguan Córdoba"),
        .init(code: "NOK", symbol: "kr",  englishName: "Norwegian Krone"),
        .init(code: "NPR", symbol: "रू",  englishName: "Nepalese Rupee"),
        .init(code: "NZD", symbol: "NZ$", englishName: "New Zealand Dollar"),
        .init(code: "OMR", symbol: "ر.ع.", englishName: "Omani Rial"),
        .init(code: "PAB", symbol: "B/.", englishName: "Panamanian Balboa"),
        .init(code: "PEN", symbol: "S/",  englishName: "Peruvian Sol"),
        .init(code: "PGK", symbol: "K",   englishName: "Papua New Guinean Kina"),
        .init(code: "PHP", symbol: "₱",   englishName: "Philippine Peso"),
        .init(code: "PKR", symbol: "₨",   englishName: "Pakistani Rupee"),
        .init(code: "PLN", symbol: "zł",  englishName: "Polish Złoty"),
        .init(code: "PYG", symbol: "₲",   englishName: "Paraguayan Guaraní"),
        .init(code: "QAR", symbol: "ر.ق", englishName: "Qatari Riyal"),
        .init(code: "RON", symbol: "lei", englishName: "Romanian Leu"),
        .init(code: "RSD", symbol: "дин.", englishName: "Serbian Dinar"),
        .init(code: "RUB", symbol: "₽",   englishName: "Russian Ruble"),
        .init(code: "RWF", symbol: "RF",  englishName: "Rwandan Franc"),
        .init(code: "SAR", symbol: "ر.س", englishName: "Saudi Riyal"),
        .init(code: "SBD", symbol: "SI$", englishName: "Solomon Islands Dollar"),
        .init(code: "SCR", symbol: "₨",   englishName: "Seychellois Rupee"),
        .init(code: "SEK", symbol: "kr",  englishName: "Swedish Krona"),
        .init(code: "SGD", symbol: "S$",  englishName: "Singapore Dollar"),
        .init(code: "SRD", symbol: "Sr$", englishName: "Surinamese Dollar"),
        .init(code: "SZL", symbol: "E",   englishName: "Swazi Lilangeni"),
        .init(code: "THB", symbol: "฿",   englishName: "Thai Baht"),
        .init(code: "TJS", symbol: "ЅМ",  englishName: "Tajikistani Somoni"),
        .init(code: "TND", symbol: "د.ت", englishName: "Tunisian Dinar"),
        .init(code: "TOP", symbol: "T$",  englishName: "Tongan Paʻanga"),
        .init(code: "TRY", symbol: "₺",   englishName: "Turkish Lira"),
        .init(code: "TTD", symbol: "TT$", englishName: "Trinidad & Tobago Dollar"),
        .init(code: "TWD", symbol: "NT$", englishName: "Taiwan Dollar"),
        .init(code: "TZS", symbol: "TSh", englishName: "Tanzanian Shilling"),
        .init(code: "UAH", symbol: "₴",   englishName: "Ukrainian Hryvnia"),
        .init(code: "UGX", symbol: "USh", englishName: "Ugandan Shilling"),
        .init(code: "UYU", symbol: "$U",  englishName: "Uruguayan Peso"),
        .init(code: "UZS", symbol: "лв",  englishName: "Uzbekistani Som"),
        .init(code: "VES", symbol: "Bs.S", englishName: "Venezuelan Bolívar"),
        .init(code: "VND", symbol: "₫",   englishName: "Vietnamese Đồng"),
        .init(code: "VUV", symbol: "VT",  englishName: "Vanuatu Vatu"),
        .init(code: "WST", symbol: "WS$", englishName: "Samoan Tala"),
        .init(code: "XAF", symbol: "FCFA", englishName: "Central African CFA Franc"),
        .init(code: "XCD", symbol: "EC$", englishName: "East Caribbean Dollar"),
        .init(code: "XOF", symbol: "CFA", englishName: "West African CFA Franc"),
        .init(code: "XPF", symbol: "₣",   englishName: "CFP Franc"),
        .init(code: "YER", symbol: "﷼",   englishName: "Yemeni Rial"),
        .init(code: "ZAR", symbol: "R",   englishName: "South African Rand"),
        .init(code: "ZMW", symbol: "ZK",  englishName: "Zambian Kwacha")
    ]

    static func currency(for code: String) -> SupportedCurrency? {
        all.first { $0.code == code }
    }
}
