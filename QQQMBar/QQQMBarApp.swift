import AppKit
import Charts
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// QQQMBar is deliberately read-only. This target contains no order API client,
// brokerage socket, or trading transport.

enum SnapshotMode: String, Codable, CaseIterable {
    case fixture, imported, live

    var label: String {
        switch self {
        case .fixture: "示例数据"
        case .imported: "已导入快照"
        case .live: "联网同步"
        }
    }
}

enum RecommendationKind: String, Codable {
    case normal, increase, decrease

    var label: String {
        switch self {
        case .normal: "按基准投入"
        case .increase: "建议多投"
        case .decrease: "建议少投"
        }
    }
}

enum GlyphState: Hashable { case normal, pending, increase, decrease, confirmed, error }

struct DataSourceInfo: Codable, Hashable {
    let name: String
    let mode: SnapshotMode
    let asOf: Date
    let notes: String?
    let accountSource: String?
    let accountAsOf: Date?
    let refreshCompletedAt: Date?

    init(name: String, mode: SnapshotMode, asOf: Date, notes: String?, accountSource: String? = nil, accountAsOf: Date? = nil, refreshCompletedAt: Date? = nil) {
        self.name = name
        self.mode = mode
        self.asOf = asOf
        self.notes = notes
        self.accountSource = accountSource
        self.accountAsOf = accountAsOf
        self.refreshCompletedAt = refreshCompletedAt
    }
}

struct QuoteSnapshot: Codable, Hashable {
    let lastPrice: Double
    let dayChangePct: Double
    let dayLow: Double?
    let dayHigh: Double?
    let ytdChangePct: Double?
    let annualizedVol30D: Double?

    init(lastPrice: Double, dayChangePct: Double, dayLow: Double? = nil, dayHigh: Double? = nil, ytdChangePct: Double?, annualizedVol30D: Double?) {
        self.lastPrice = lastPrice
        self.dayChangePct = dayChangePct
        self.dayLow = dayLow
        self.dayHigh = dayHigh
        self.ytdChangePct = ytdChangePct
        self.annualizedVol30D = annualizedVol30D
    }
}

struct PortfolioSnapshot: Codable, Hashable {
    let shares: Double
    let marketValue: Double
    let averageCost: Double
    let unrealizedPnL: Double
    let nav: Double
    let availableFunds: Double

    var positionWeight: Double { nav > 0 ? marketValue / nav : 0 }
    var availableFundsWeight: Double { nav > 0 ? availableFunds / nav : 0 }
}

struct PricePoint: Identifiable, Codable, Hashable {
    var id: Date { date }
    let date: Date
    let close: Double
}

struct BuyMarker: Identifiable, Codable, Hashable {
    let id: String
    let date: Date
    let price: Double
    let quantity: Double
    let amount: Double
}

struct DCARecommendation: Codable, Hashable {
    let id: String
    let baseAmount: Double
    let recommendedAmount: Double
    let kind: RecommendationKind
    let nextExecution: Date
    let generatedAt: Date
    let explanation: String

    var multiplier: Double { baseAmount > 0 ? recommendedAmount / baseAmount : 1 }
}

private enum DCAAllocationBand: String, CaseIterable {
    case strongIncrease, increase, normal, decrease, strongDecrease

    var kind: RecommendationKind {
        switch self {
        case .strongIncrease, .increase: .increase
        case .normal: .normal
        case .decrease, .strongDecrease: .decrease
        }
    }

    var multiplier: Double {
        switch self {
        case .strongIncrease: 1.50
        case .increase: 1.25
        case .normal: 1.00
        case .decrease: 0.75
        case .strongDecrease: 0.50
        }
    }

    var label: String {
        switch self {
        case .strongIncrease: "明显多投"
        case .increase: "适度多投"
        case .normal: "按基准投入"
        case .decrease: "适度少投"
        case .strongDecrease: "明显少投"
        }
    }
}

private enum DCAThresholds {
    static let strongMoreMomentum = -10.0
    static let moreMomentum = -5.0
    static let lessMomentum = 8.0
    static let strongLessMomentum = 15.0
    static let strongMoreSentiment = 25.0
    static let moreSentiment = 40.0
    static let lessSentiment = 65.0
    static let strongLessSentiment = 75.0
    static let strongMoreVIX = 32.0
    static let moreVIX = 25.0
    static let lessVIX = 22.0
    static let strongLessVIX = 18.0
}

private struct DCAConditionAudit: Equatable {
    let momentum: Double
    let vix: Double?
    let sentiment: Double

    var moreChecks: [Bool] {
        [momentum <= DCAThresholds.moreMomentum, sentiment < DCAThresholds.moreSentiment, vix.map { $0 >= DCAThresholds.moreVIX } ?? false]
    }
    var lessChecks: [Bool] {
        [momentum >= DCAThresholds.lessMomentum, sentiment >= DCAThresholds.lessSentiment, vix.map { $0 < DCAThresholds.lessVIX } ?? false]
    }
    var moreCount: Int { moreChecks.filter { $0 }.count }
    var lessCount: Int { lessChecks.filter { $0 }.count }
    var band: DCAAllocationBand { dcaAllocationBand(momentum: momentum, vix: vix, sentimentScore: sentiment) }

    // Positive values are the remaining distance to the standard tier.
    // The ordering is always trend, sentiment, VIX so the UI and tests share
    // the exact same decision semantics as dcaAllocationBand.
    var moreGaps: [Double] {
        [
            max(0, momentum - DCAThresholds.moreMomentum),
            max(0, sentiment - DCAThresholds.moreSentiment),
            max(0, DCAThresholds.moreVIX - (vix ?? DCAThresholds.lessVIX))
        ]
    }
    var lessGaps: [Double] {
        [
            max(0, DCAThresholds.lessMomentum - momentum),
            max(0, DCAThresholds.lessSentiment - sentiment),
            max(0, (vix ?? DCAThresholds.lessVIX) - DCAThresholds.lessVIX)
        ]
    }
}

private func dcaAllocationBand(momentum: Double, vix: Double?, sentimentScore: Double) -> DCAAllocationBand {
    if momentum <= DCAThresholds.strongMoreMomentum || sentimentScore <= DCAThresholds.strongMoreSentiment || (vix.map { $0 >= DCAThresholds.strongMoreVIX } ?? false) { return .strongIncrease }
    if momentum <= DCAThresholds.moreMomentum || sentimentScore < DCAThresholds.moreSentiment || (vix.map { $0 >= DCAThresholds.moreVIX } ?? false) { return .increase }
    if momentum >= DCAThresholds.strongLessMomentum && sentimentScore >= DCAThresholds.strongLessSentiment && (vix.map { $0 < DCAThresholds.strongLessVIX } ?? false) { return .strongDecrease }
    if momentum >= DCAThresholds.lessMomentum && sentimentScore >= DCAThresholds.lessSentiment && (vix.map { $0 < DCAThresholds.lessVIX } ?? false) { return .decrease }
    return .normal
}

private enum MarketRefreshSchedule {
    static let marketTimeZone = TimeZone(identifier: "America/New_York")!
    static let hour = 16
    static let minute = 5
    static let initialRetryInterval: TimeInterval = 5 * 60
    static let lateRetryInterval: TimeInterval = 30 * 60
    static let retryCutoffHour = 20
    static let retryCutoffMinute = 15

    static func nextRefresh(after date: Date) -> Date {
        scheduledDate(relativeTo: date, direction: 1, includeCurrent: false)
    }

    static func mostRecentRefresh(onOrBefore date: Date) -> Date {
        scheduledDate(relativeTo: date, direction: -1, includeCurrent: true)
    }

    static func isDue(lastRefresh: Date?, now: Date = Date()) -> Bool {
        guard let lastRefresh else { return true }
        return lastRefresh < mostRecentRefresh(onOrBefore: now)
    }

    static func expectedSessionDate(at date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone
        let today = calendar.startOfDay(for: date)
        let scheduledToday = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
        var candidate = date >= scheduledToday ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while !isTradingDay(candidate, calendar: calendar) {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate)!
        }
        return utcDate(forMarketDay: candidate, calendar: calendar)
    }

    static func isFresh(marketDate: Date?, now: Date = Date()) -> Bool {
        guard let marketDate else { return false }
        return utcDayKey(marketDate) >= utcDayKey(expectedSessionDate(at: now))
    }

    static func marketSessionDate(for timestamp: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone
        return utcDate(forMarketDay: timestamp, calendar: calendar)
    }

    static func retryDate(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone
        let day = calendar.startOfDay(for: date)
        guard isTradingDay(day, calendar: calendar),
              let cutoff = calendar.date(bySettingHour: retryCutoffHour, minute: retryCutoffMinute, second: 0, of: day),
              date < cutoff else { return nil }
        let firstWindowEnd = calendar.date(bySettingHour: 16, minute: 20, second: 0, of: day)!
        let interval = date < firstWindowEnd ? initialRetryInterval : lateRetryInterval
        return min(date.addingTimeInterval(interval), cutoff)
    }

    private static func scheduledDate(relativeTo date: Date, direction: Int, includeCurrent: Bool) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone
        let start = calendar.startOfDay(for: date)
        let offsets = direction > 0 ? Array(0...8) : Array((0...8).map { -$0 })
        for offset in offsets {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            let weekday = calendar.component(.weekday, from: candidate)
            guard (2...6).contains(weekday), isTradingDay(candidate, calendar: calendar) else { continue }
            if direction > 0 {
                if candidate > date || (includeCurrent && candidate == date) { return candidate }
            } else if candidate < date || (includeCurrent && candidate == date) {
                return candidate
            }
        }
        return date.addingTimeInterval(Double(direction) * 86_400)
    }

    private static func isTradingDay(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        return !marketHolidays(in: calendar.component(.year, from: date), calendar: calendar).contains(calendar.startOfDay(for: date))
    }

    private static func marketHolidays(in year: Int, calendar: Calendar) -> Set<Date> {
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        func observed(_ date: Date) -> Date {
            switch calendar.component(.weekday, from: date) {
            case 7: return calendar.date(byAdding: .day, value: -1, to: date)!
            case 1: return calendar.date(byAdding: .day, value: 1, to: date)!
            default: return date
            }
        }
        func nthWeekday(_ weekday: Int, month: Int, ordinal: Int) -> Date {
            var components = DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: ordinal)
            components.calendar = calendar
            return calendar.date(from: components)!
        }
        func lastWeekday(_ weekday: Int, month: Int) -> Date {
            var components = DateComponents(year: year, month: month + 1, day: 0)
            components.calendar = calendar
            var value = calendar.date(from: components)!
            while calendar.component(.weekday, from: value) != weekday {
                value = calendar.date(byAdding: .day, value: -1, to: value)!
            }
            return value
        }
        func easterSunday() -> Date {
            let a = year % 19, b = year / 100, c = year % 100
            let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
            let h = (19 * a + b - d - g + 15) % 30
            let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
            let m = (a + 11 * h + 22 * l) / 451
            let month = (h + l - 7 * m + 114) / 31
            let day = (h + l - 7 * m + 114) % 31 + 1
            return date(month, day)
        }

        let newYear = observed(date(1, 1))
        let nextNewYearObserved = observed(calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!)
        var holidays: Set<Date> = [
            newYear,
            nthWeekday(2, month: 1, ordinal: 3),
            nthWeekday(2, month: 2, ordinal: 3),
            calendar.date(byAdding: .day, value: -2, to: easterSunday())!,
            lastWeekday(2, month: 5),
            observed(date(6, 19)),
            observed(date(7, 4)),
            nthWeekday(2, month: 9, ordinal: 1),
            nthWeekday(5, month: 11, ordinal: 4),
            observed(date(12, 25))
        ]
        if calendar.component(.year, from: nextNewYearObserved) == year { holidays.insert(nextNewYearObserved) }
        return Set(holidays.map { calendar.startOfDay(for: $0) })
    }

    private static func utcDate(forMarketDay date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: components)!
    }

    private static func utcDayKey(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }
}

struct MarketSignal: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let value: String
    let normalized: Double?
    let source: String
    let asOf: Date
    let mode: SnapshotMode
}

struct QQQMSnapshot: Codable, Hashable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let symbol: String
    let source: DataSourceInfo
    let quote: QuoteSnapshot
    let portfolio: PortfolioSnapshot
    let priceHistory: [PricePoint]
    let buyMarkers: [BuyMarker]
    let recommendation: DCARecommendation
    let signals: [MarketSignal]

    var lastUpdated: Date { source.asOf }
    var verifiedMarketValue: Double { portfolio.shares * quote.lastPrice }
    var verifiedUnrealizedPnL: Double { portfolio.shares * (quote.lastPrice - portfolio.averageCost) }
    var verifiedNAV: Double { portfolio.nav + verifiedMarketValue - portfolio.marketValue }
    var verifiedPositionWeight: Double { verifiedNAV > 0 ? verifiedMarketValue / verifiedNAV : 0 }
    var verifiedAvailableFundsWeight: Double { verifiedNAV > 0 ? portfolio.availableFunds / verifiedNAV : 0 }
    var monthMomentumPct: Double {
        guard let first = priceHistory.first?.close, first != 0 else { return 0 }
        return (quote.lastPrice / first - 1) * 100
    }
    var auditIssues: [String] {
        var issues: [String] = []
        if priceHistory.isEmpty { issues.append("缺少价格历史") }
        if priceHistory.contains(where: { !$0.close.isFinite || $0.close <= 0 }) { issues.append("价格历史含无效值") }
        if zip(priceHistory, priceHistory.dropFirst()).contains(where: { $0.0.date >= $0.1.date }) { issues.append("价格历史未按日期递增") }
        if !quote.lastPrice.isFinite || quote.lastPrice <= 0 { issues.append("最新价无效") }
        let marketTolerance = max(0.02, verifiedMarketValue * 0.001)
        if abs(portfolio.marketValue - verifiedMarketValue) > marketTolerance { issues.append("市值与股数/最新价不一致") }
        if abs(portfolio.unrealizedPnL - verifiedUnrealizedPnL) > max(0.02, marketTolerance) { issues.append("未实现盈亏与成本/最新价不一致") }
        if buyMarkers.contains(where: { abs($0.amount - $0.price * abs($0.quantity)) > 0.02 }) { issues.append("成交记录金额不一致") }
        if let low = quote.dayLow, let high = quote.dayHigh, (low > high || quote.lastPrice < low || quote.lastPrice > high) { issues.append("最新价不在日内范围内") }
        return issues
    }

    func freshnessIssues(at now: Date = Date()) -> [String] {
        var issues: [String] = []
        let expectedSession = MarketRefreshSchedule.expectedSessionDate(at: now)
        func reachesExpectedSession(_ date: Date?) -> Bool {
            guard let date else { return false }
            return MarketRefreshSchedule.isFresh(marketDate: date, now: now)
        }
        if !reachesExpectedSession(priceHistory.last?.date) || !reachesExpectedSession(source.asOf) {
            issues.append("QQQM 行情未更新到最新交易日")
        }
        if !reachesExpectedSession(recommendation.generatedAt) {
            issues.append("定投结论未按最新交易日重算")
        }
        for id in ["live-momentum", "live-vix", "live-cnn-fear-greed"] {
            guard let signal = signals.first(where: { $0.id == id }), reachesExpectedSession(signal.asOf) else {
                let label = id == "live-vix" ? "VIX" : (id == "live-cnn-fear-greed" ? "CNN 指数" : "趋势")
                issues.append("\(label) 未更新到最新交易日")
                continue
            }
        }
        if source.accountSource != nil {
            guard let accountAsOf = source.accountAsOf,
                  MarketRefreshSchedule.marketSessionDate(for: accountAsOf) >= expectedSession else {
                issues.append("IBKR 账户未同步到最新交易日")
                return issues
            }
        }
        return issues
    }

    static let fixture: QQQMSnapshot = {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T13:30:00Z")! }
        let history = [
            ("2026-07-30", 281.35), ("2026-07-31", 283.29), ("2026-08-03", 288.27),
            ("2026-08-04", 298.03), ("2026-08-05", 295.35), ("2026-08-06", 294.26),
            ("2026-08-07", 297.70), ("2026-08-10", 296.85), ("2026-08-11", 295.83),
            ("2026-08-12", 297.98), ("2026-08-13", 301.41), ("2026-08-14", 301.01),
            ("2026-08-17", 300.52), ("2026-08-18", 295.45), ("2026-08-19", 294.85),
            ("2026-08-20", 292.79), ("2026-08-21", 293.76), ("2026-08-24", 290.81),
            ("2026-08-25", 292.66), ("2026-08-26", 292.90), ("2026-08-27", 296.92),
            ("2026-08-28", 295.00)
        ].map { PricePoint(date: date($0.0), close: $0.1) }
        let updated = ISO8601DateFormatter().date(from: "2026-08-28T20:00:00Z")!
        return QQQMSnapshot(
            schemaVersion: currentSchemaVersion,
            symbol: "QQQM",
            source: DataSourceInfo(name: "Bundled development fixture", mode: .fixture, asOf: updated, notes: "收盘行情经历史行情源交叉核对；账户数据仍为开发 fixture，不是实时 IBKR 数据。"),
            quote: QuoteSnapshot(lastPrice: 295.00, dayChangePct: (295.00 / 296.92 - 1) * 100, dayLow: 294.45, dayHigh: 298.16, ytdChangePct: 16.50, annualizedVol30D: 19.5056),
            portfolio: PortfolioSnapshot(shares: 1, marketValue: 295, averageCost: 300, unrealizedPnL: -5, nav: 10_000, availableFunds: 1_200),
            priceHistory: history,
            buyMarkers: [
                BuyMarker(id: "fixture-example-buy", date: date("2026-08-18"), price: 300, quantity: 1, amount: 300)
            ],
            recommendation: DCARecommendation(id: "fixture-plan-2026-09-01-v1", baseAmount: 400, recommendedAmount: 400, kind: .normal, nextExecution: ISO8601DateFormatter().date(from: "2026-09-01T13:30:00Z")!, generatedAt: updated, explanation: "开发 fixture：维持每周基准计划。"),
            signals: [
                MarketSignal(id: "fixture-momentum", title: "30D 趋势", value: "+4.9%", normalized: 0.74, source: "QQQM 日线", asOf: updated, mode: .fixture),
                MarketSignal(id: "fixture-vix", title: "VIX", value: "14.5", normalized: 0.36, source: "FRED · 8/27", asOf: updated, mode: .fixture),
                MarketSignal(id: "fixture-cnn-fear-greed", title: "CNN 恐惧贪婪", value: "示例 50", normalized: 0.50, source: "开发 fixture", asOf: updated, mode: .fixture),
                MarketSignal(id: "fixture-valuation", title: "QQQM P/E", value: "36.52×", normalized: 0.73, source: "Invesco · 3/31", asOf: updated, mode: .fixture)
            ]
        )
    }()
}

enum LiveMarketDataError: LocalizedError {
    case invalidResponse(String)
    case insufficientHistory(Int)
    case staleMarketDate(expected: Date, received: Date?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let source): "\(source) 返回的数据无法解析"
        case .insufficientHistory(let count): "Nasdaq 日线数量不足：\(count)"
        case .staleMarketDate(let expected, let received):
            "Nasdaq 尚未发布 \(Self.dayLabel(expected)) 收盘数据（当前最新：\(received.map(Self.dayLabel) ?? "无")），稍后自动重试"
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

struct NasdaqOfficialClose: Hashable {
    let date: Date
    let close: Double
    let previousClose: Double
    let low: Double?
    let high: Double?
}

struct VIXObservation: Hashable {
    let date: Date
    let value: Double
}

struct CNNFearGreedObservation: Hashable {
    let date: Date
    let score: Double
    let rating: String

    var localizedRating: String {
        switch rating.lowercased() {
        case "extreme fear": "极度恐惧"
        case "fear": "恐惧"
        case "greed": "贪婪"
        case "extreme greed": "极度贪婪"
        default: "中性"
        }
    }
}

struct CNNMarketObservation: Hashable {
    let fearGreed: CNNFearGreedObservation
    let vix: VIXObservation
}

struct LiveMarketDataService {
    // Official fund fact sheet, Q1 2026. This is intentionally a dated
    // fundamental snapshot rather than a made-up real-time valuation score.
    static let officialPERatio = 36.52
    static let officialPEAsOf = ISO8601DateFormatter().date(from: "2026-03-31T20:00:00Z")!

    func refreshedSnapshot(from current: QQQMSnapshot, now: Date = Date(), confirmedRecommendationID: String? = nil) async throws -> QQQMSnapshot {
        async let nasdaqTask = fetchNasdaqHistory()
        async let closeTask = fetchNasdaqOfficialClose()
        async let fredVIXTask = fetchLatestVIX()
        async let cnnTask = fetchCNNMarketObservation()
        var allHistory = try await nasdaqTask
        let officialClose = try await closeTask
        let cnnMarket = try? await cnnTask
        let fredVIX = try? await fredVIXTask
        let vix = cnnMarket?.vix ?? fredVIX
        let cnn = cnnMarket?.fearGreed
        if let index = allHistory.lastIndex(where: { Self.utcDayKey($0.date) == Self.utcDayKey(officialClose.date) }) {
            allHistory[index] = PricePoint(date: officialClose.date, close: officialClose.close)
        } else if allHistory.last.map({ Self.utcDayKey($0.date) < Self.utcDayKey(officialClose.date) }) ?? true {
            allHistory.append(PricePoint(date: officialClose.date, close: officialClose.close))
        }
        allHistory.sort { $0.date < $1.date }
        guard allHistory.count >= 30 else { throw LiveMarketDataError.insufficientHistory(allHistory.count) }

        let expectedSession = MarketRefreshSchedule.expectedSessionDate(at: now)
        guard MarketRefreshSchedule.isFresh(marketDate: allHistory.last?.date, now: now) else {
            throw LiveMarketDataError.staleMarketDate(expected: expectedSession, received: allHistory.last?.date)
        }

        let chartHistory = Array(allHistory.suffix(30))
        guard let latest = allHistory.last, allHistory.count >= 2 else {
            throw LiveMarketDataError.insufficientHistory(allHistory.count)
        }
        let previous = allHistory[allHistory.count - 2]
        let yearStart = allHistory.first!
        let dayChange = (latest.close / previous.close - 1) * 100
        let ytd = (latest.close / yearStart.close - 1) * 100
        let volatility = annualizedVolatility(Array(allHistory.suffix(31)).map(\.close))
        let momentum = (latest.close / chartHistory.first!.close - 1) * 100
        let rsi = relativeStrengthIndex(Array(allHistory.suffix(15)).map(\.close))
        let riskAppetite = vix.map { clamp((32 - $0.value) / 22 * 100) } ?? 50
        let trendScore = clamp(50 + momentum * 4.2)
        let modelSentimentScore = clamp(rsi * 0.55 + riskAppetite * 0.30 + trendScore * 0.15)
        let cachedCNN = current.signals.first { $0.id == "live-cnn-fear-greed" && $0.normalized != nil }
        let cnnScore = cnn?.score ?? cachedCNN?.normalized.map { $0 * 100 }
        let sentimentScore = cnnScore ?? modelSentimentScore

        let recommendation = liveRecommendation(
            from: current.recommendation,
            marketDate: latest.date,
            confirmedRecommendationID: confirmedRecommendationID,
            momentum: momentum,
            vix: vix?.value,
            sentimentScore: sentimentScore,
            sentimentSource: cnnScore == nil ? "RSI+VIX 备用模型" : "CNN 指数"
        )

        let updatedMarketValue = current.portfolio.shares * latest.close
        let updatedPnL = current.portfolio.shares * (latest.close - current.portfolio.averageCost)
        let updatedNAV = current.verifiedNAV + updatedMarketValue - current.verifiedMarketValue
        let updatedPortfolio = PortfolioSnapshot(
            shares: current.portfolio.shares,
            marketValue: updatedMarketValue,
            averageCost: current.portfolio.averageCost,
            unrealizedPnL: updatedPnL,
            nav: updatedNAV,
            availableFunds: current.portfolio.availableFunds
        )
        let vixValue = vix.map { String(format: "%.1f", $0.value) } ?? "—"
        let vixProvider = cnnMarket?.vix == nil ? "FRED 后备" : "CNN VIX"
        let vixSource = vix.map { "\(vixProvider) · \(Self.marketDayLabel($0.date))" } ?? "VIX 暂不可用"
        let accountNote = current.source.accountSource == nil ? "账户数据为本地快照。" : "账户数据由 IBKR 插件同步。"
        let sourceNotes = "QQQM 收盘与日线：Nasdaq；VIX 与恐惧贪婪：CNN 同批次，FRED 仅后备；P/E：Invesco 最新官方季度数据。\(accountNote)"
        let cnnSignal: MarketSignal
        if let cnn {
            cnnSignal = MarketSignal(
                id: "live-cnn-fear-greed",
                title: "CNN 恐惧贪婪",
                value: "\(cnn.localizedRating) \(Int(cnn.score.rounded()))",
                normalized: clamp(cnn.score) / 100,
                source: "CNN · \(Self.marketDayLabel(cnn.date))",
                asOf: cnn.date,
                mode: .live
            )
        } else if let cachedCNN {
            cnnSignal = MarketSignal(
                id: cachedCNN.id,
                title: "CNN 恐惧贪婪",
                value: cachedCNN.value,
                normalized: cachedCNN.normalized,
                source: "CNN 缓存 · \(Self.marketDayLabel(cachedCNN.asOf))",
                asOf: cachedCNN.asOf,
                mode: .live
            )
        } else {
            cnnSignal = MarketSignal(id: "live-cnn-fear-greed", title: "CNN 恐惧贪婪", value: "—", normalized: nil, source: "CNN 暂不可用", asOf: latest.date, mode: .live)
        }

        return QQQMSnapshot(
            schemaVersion: QQQMSnapshot.currentSchemaVersion,
            symbol: current.symbol,
            source: DataSourceInfo(
                name: current.source.accountSource == nil ? "Nasdaq + CNN + Invesco" : "IBKR + Nasdaq + CNN + Invesco",
                mode: .live,
                asOf: latest.date,
                notes: sourceNotes,
                accountSource: current.source.accountSource,
                accountAsOf: current.source.accountAsOf,
                refreshCompletedAt: now
            ),
            quote: QuoteSnapshot(
                lastPrice: latest.close,
                dayChangePct: dayChange,
                dayLow: officialClose.low,
                dayHigh: officialClose.high,
                ytdChangePct: ytd,
                annualizedVol30D: volatility
            ),
            portfolio: updatedPortfolio,
            priceHistory: chartHistory,
            buyMarkers: current.buyMarkers,
            recommendation: recommendation,
            signals: [
                MarketSignal(id: "live-momentum", title: "30D 趋势", value: String(format: "%+.1f%%", momentum), normalized: trendScore / 100, source: "Nasdaq · 30 日", asOf: latest.date, mode: .live),
                MarketSignal(id: "live-vix", title: "VIX", value: vixValue, normalized: vix.map { min(max($0.value / 40, 0), 1) }, source: vixSource, asOf: vix?.date ?? latest.date, mode: .live),
                cnnSignal,
                MarketSignal(id: "live-valuation", title: "QQQM P/E", value: String(format: "%.2f×", Self.officialPERatio), normalized: clamp(Self.officialPERatio / 50), source: "Invesco · 3/31", asOf: Self.officialPEAsOf, mode: .live)
            ]
        )
    }

    func fetchNasdaqHistory() async throws -> [PricePoint] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let url = URL(string: "https://api.nasdaq.com/api/quote/QQQM/historical?assetclass=etf&fromdate=\(year)-01-01&limit=500")!
        let data = try await request(url, referer: "https://www.nasdaq.com/")
        return try Self.parseNasdaqHistory(data)
    }

    func fetchLatestNasdaqBar() async throws -> (low: Double, high: Double) {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let url = URL(string: "https://api.nasdaq.com/api/quote/QQQM/historical?assetclass=etf&fromdate=\(year)-01-01&limit=5")!
        let data = try await request(url, referer: "https://www.nasdaq.com/")
        let rows = try Self.nasdaqRows(data)
        guard let row = rows.first,
              let low = Self.number(row["low"]), let high = Self.number(row["high"]) else {
            throw LiveMarketDataError.invalidResponse("Nasdaq 日内行情")
        }
        return (low, high)
    }

    func fetchNasdaqOfficialClose() async throws -> NasdaqOfficialClose {
        let infoURL = URL(string: "https://api.nasdaq.com/api/quote/QQQM/info?assetclass=etf")!
        let summaryURL = URL(string: "https://api.nasdaq.com/api/quote/QQQM/summary?assetclass=etf")!
        async let infoData = request(infoURL, referer: "https://www.nasdaq.com/")
        async let summaryData = request(summaryURL, referer: "https://www.nasdaq.com/")
        return try Self.parseNasdaqOfficialClose(infoData: await infoData, summaryData: await summaryData)
    }

    func fetchLatestVIX() async throws -> VIXObservation {
        let url = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=VIXCLS")!
        return try Self.parseLatestVIX(try await request(url))
    }

    func fetchCNNMarketObservation() async throws -> CNNMarketObservation {
        let url = URL(string: "https://production.dataviz.cnn.io/index/fearandgreed/graphdata")!
        let data = try await request(url, referer: "https://www.cnn.com/markets/fear-and-greed", browserCompatible: true)
        return try Self.parseCNNMarketObservation(data)
    }

    private func request(_ url: URL, referer: String? = nil, browserCompatible: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        request.setValue(browserCompatible ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140 Safari/537.36" : "QQQMBar/0.13 macOS", forHTTPHeaderField: "User-Agent")
        request.setValue(browserCompatible ? "application/json, text/plain, */*" : "application/json,text/csv;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if browserCompatible { request.setValue("https://www.cnn.com", forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LiveMarketDataError.invalidResponse(url.host ?? "网络数据源")
        }
        return data
    }

    static func parseNasdaqHistory(_ data: Data) throws -> [PricePoint] {
        let rows = try nasdaqRows(data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd/yyyy"
        let points = rows.compactMap { row -> PricePoint? in
            guard let rawDate = row["date"], let close = number(row["close"]),
                  let date = formatter.date(from: rawDate) else { return nil }
            return PricePoint(date: date, close: close)
        }.sorted { $0.date < $1.date }
        guard !points.isEmpty else { throw LiveMarketDataError.invalidResponse("Nasdaq 历史行情") }
        return points
    }

    static func parseNasdaqOfficialClose(infoData: Data, summaryData: Data) throws -> NasdaqOfficialClose {
        guard let infoRoot = try JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let info = infoRoot["data"] as? [String: Any],
              let secondary = info["secondaryData"] as? [String: Any],
              let timestamp = secondary["lastTradeTimestamp"] as? String,
              let close = number(secondary["lastSalePrice"].map(String.init(describing:))),
              timestamp.hasPrefix("Closed at ") else {
            throw LiveMarketDataError.invalidResponse("Nasdaq 官方收盘价")
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = MarketRefreshSchedule.marketTimeZone
        dateFormatter.dateFormat = "MMM d, yyyy h:mm a 'ET'"
        guard let tradeDate = dateFormatter.date(from: String(timestamp.dropFirst("Closed at ".count))) else {
            throw LiveMarketDataError.invalidResponse("Nasdaq 收盘时间")
        }
        var marketCalendar = Calendar(identifier: .gregorian)
        marketCalendar.timeZone = MarketRefreshSchedule.marketTimeZone
        let marketParts = marketCalendar.dateComponents([.year, .month, .day], from: tradeDate)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let marketDate = utcCalendar.date(from: marketParts),
              let summaryRoot = try JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
              let summary = summaryRoot["data"] as? [String: Any],
              let summaryData = summary["summaryData"] as? [String: Any],
              let previousEntry = summaryData["PreviousClose"] as? [String: Any],
              let previousClose = number(previousEntry["value"].map(String.init(describing:))),
              let rangeEntry = summaryData["TodayHighLow"] as? [String: Any],
              let range = rangeEntry["value"] as? String else {
            throw LiveMarketDataError.invalidResponse("Nasdaq 收盘摘要")
        }
        let bounds = range.split(separator: "/", omittingEmptySubsequences: false).compactMap { number(String($0)) }
        // Nasdaq may publish the official close before it backfills the
        // intraday range. A missing auxiliary range must not block the
        // verified closing-price batch or make it look stale.
        return NasdaqOfficialClose(date: marketDate, close: close, previousClose: previousClose, low: bounds.min(), high: bounds.max())
    }

    private static func utcDayKey(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    static func parseLatestVIX(_ data: Data) throws -> VIXObservation {
        guard let csv = String(data: data, encoding: .utf8) else { throw LiveMarketDataError.invalidResponse("FRED VIX") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        for line in csv.split(whereSeparator: \.isNewline).reversed() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2, let date = formatter.date(from: String(fields[0])), let value = Double(fields[1]) else { continue }
            return VIXObservation(date: date, value: value)
        }
        throw LiveMarketDataError.invalidResponse("FRED VIX")
    }

    static func parseCNNFearGreed(_ data: Data) throws -> CNNFearGreedObservation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["fear_and_greed"] as? [String: Any],
              let score = current["score"] as? Double,
              let rating = current["rating"] as? String,
              let timestamp = current["timestamp"] as? String,
              let date = ISO8601DateFormatter().date(from: timestamp),
              score.isFinite, (0...100).contains(score) else {
            throw LiveMarketDataError.invalidResponse("CNN 恐惧与贪婪指数")
        }
        return CNNFearGreedObservation(date: date, score: score, rating: rating)
    }

    static func parseCNNMarketObservation(_ data: Data) throws -> CNNMarketObservation {
        let fearGreed = try parseCNNFearGreed(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let volatility = root["market_volatility_vix"] as? [String: Any],
              let rows = volatility["data"] as? [[String: Any]],
              let latest = rows.last,
              let timestampMilliseconds = latest["x"] as? Double,
              let value = latest["y"] as? Double,
              timestampMilliseconds.isFinite, value.isFinite, value > 0 else {
            throw LiveMarketDataError.invalidResponse("CNN VIX")
        }
        return CNNMarketObservation(
            fearGreed: fearGreed,
            vix: VIXObservation(date: Date(timeIntervalSince1970: timestampMilliseconds / 1000), value: value)
        )
    }

    private static func marketDayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private static func nasdaqRows(_ data: Data) throws -> [[String: String]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let table = payload["tradesTable"] as? [String: Any],
              let rows = table["rows"] as? [[String: Any]] else {
            throw LiveMarketDataError.invalidResponse("Nasdaq")
        }
        return rows.map { row in row.reduce(into: [String: String]()) { result, pair in result[pair.key] = String(describing: pair.value) } }
    }

    private static func number(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func annualizedVolatility(_ prices: [Double]) -> Double? {
        guard prices.count > 2 else { return nil }
        let returns = zip(prices.dropFirst(), prices).map { log($0.0 / $0.1) }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.map { pow($0 - mean, 2) }.reduce(0, +) / Double(max(returns.count - 1, 1))
        return sqrt(variance) * sqrt(252) * 100
    }

    private func relativeStrengthIndex(_ prices: [Double]) -> Double {
        guard prices.count > 1 else { return 50 }
        let changes = zip(prices.dropFirst(), prices).map { $0.0 - $0.1 }
        let gains = changes.map { max($0, 0) }.reduce(0, +) / Double(changes.count)
        let losses = changes.map { max(-$0, 0) }.reduce(0, +) / Double(changes.count)
        guard losses > 0 else { return 100 }
        return 100 - 100 / (1 + gains / losses)
    }

    private func liveRecommendation(from current: DCARecommendation, marketDate: Date, confirmedRecommendationID: String?, momentum: Double, vix: Double?, sentimentScore: Double, sentimentSource: String) -> DCARecommendation {
        let baseAmount = 400.0
        let band = dcaAllocationBand(momentum: momentum, vix: vix, sentimentScore: sentimentScore)
        let amount = baseAmount * band.multiplier
        var nextExecution = current.nextExecution
        if confirmedRecommendationID == current.id {
            var marketCalendar = Calendar(identifier: .gregorian)
            marketCalendar.timeZone = MarketRefreshSchedule.marketTimeZone
            // Nasdaq market dates are encoded as UTC midnight; interpreting
            // them again in New York would incorrectly shift them back a day.
            let marketSession = marketDate
            while MarketRefreshSchedule.marketSessionDate(for: nextExecution) <= marketSession {
                nextExecution = marketCalendar.date(byAdding: .weekOfYear, value: 1, to: nextExecution)!
            }
        }
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: nextExecution)
        let executionDay = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let vixText = vix.map { String(format: "%.1f", $0) } ?? "暂不可用"
        return DCARecommendation(
            id: "live-plan-\(executionDay)-\(band.rawValue)-\(Int(amount))",
            baseAmount: baseAmount,
            recommendedAmount: amount,
            kind: band.kind,
            nextExecution: nextExecution,
            generatedAt: marketDate,
            explanation: String(format: "US$400 分档规则：QQQM 30 日涨跌 %+.2f%%，VIX %@，%@ %.0f/100；当前为“%@”，采用 %.2f×，本期 US$%.0f。只提供计划提醒，不会自动下单。", momentum, vixText, sentimentSource, sentimentScore, band.label, band.multiplier, amount)
        )
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 100) }
}

struct PlanConfirmation: Codable, Hashable {
    let recommendationID: String
    let confirmedAt: Date
}

enum SnapshotStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidSymbol(String)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "不支持的快照版本：\(version)"
        case .invalidSymbol(let symbol): "快照标的必须为 QQQM，当前为 \(symbol)"
        case .invalidSnapshot(let reason): "快照校验失败：\(reason)"
        }
    }
}

final class SnapshotStore {
    static let shared = SnapshotStore()
    private let fileManager = FileManager.default

    var folderURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QQQMBar", isDirectory: true)
    }
    var snapshotURL: URL { folderURL.appendingPathComponent("snapshot-v2.json") }
    private var confirmationURL: URL { folderURL.appendingPathComponent("plan-confirmation.json") }

    func prepareInitialSnapshot() throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: snapshotURL.path) else { try save(QQQMSnapshot.fixture); return }
        if let existing = try? decoder.decode(QQQMSnapshot.self, from: Data(contentsOf: snapshotURL)), existing.source.mode == .fixture {
            try save(QQQMSnapshot.fixture)
        }
    }

    func load() throws -> QQQMSnapshot {
        let snapshot = try decoder.decode(QQQMSnapshot.self, from: Data(contentsOf: snapshotURL))
        try validate(snapshot)
        return snapshot
    }

    func importSnapshot(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let snapshot = try decoder.decode(QQQMSnapshot.self, from: Data(contentsOf: url))
        try validate(snapshot)
        try save(snapshot)
    }

    func save(_ snapshot: QQQMSnapshot) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    func loadConfirmation() throws -> PlanConfirmation? {
        guard fileManager.fileExists(atPath: confirmationURL.path) else { return nil }
        return try decoder.decode(PlanConfirmation.self, from: Data(contentsOf: confirmationURL))
    }

    func saveConfirmation(_ confirmation: PlanConfirmation?) throws {
        guard let confirmation else {
            if fileManager.fileExists(atPath: confirmationURL.path) { try fileManager.removeItem(at: confirmationURL) }
            return
        }
        try encoder.encode(confirmation).write(to: confirmationURL, options: .atomic)
    }

    private func validate(_ snapshot: QQQMSnapshot) throws {
        guard snapshot.schemaVersion == QQQMSnapshot.currentSchemaVersion else { throw SnapshotStoreError.unsupportedSchema(snapshot.schemaVersion) }
        guard snapshot.symbol.uppercased() == "QQQM" else { throw SnapshotStoreError.invalidSymbol(snapshot.symbol) }
        guard snapshot.portfolio.shares.isFinite, snapshot.portfolio.shares >= 0 else { throw SnapshotStoreError.invalidSnapshot("持仓股数无效") }
        guard snapshot.portfolio.averageCost.isFinite, snapshot.portfolio.averageCost >= 0 else { throw SnapshotStoreError.invalidSnapshot("平均成本无效") }
        guard snapshot.portfolio.nav.isFinite, snapshot.portfolio.nav > 0 else { throw SnapshotStoreError.invalidSnapshot("账户 NAV 无效") }
        guard snapshot.portfolio.availableFunds.isFinite, snapshot.portfolio.availableFunds >= 0 else { throw SnapshotStoreError.invalidSnapshot("可用资金无效") }
        guard !snapshot.priceHistory.isEmpty else { throw SnapshotStoreError.invalidSnapshot("缺少价格历史") }
        guard snapshot.priceHistory.allSatisfy({ $0.close.isFinite && $0.close > 0 }) else { throw SnapshotStoreError.invalidSnapshot("价格历史含无效值") }
        guard !zip(snapshot.priceHistory, snapshot.priceHistory.dropFirst()).contains(where: { $0.0.date >= $0.1.date }) else { throw SnapshotStoreError.invalidSnapshot("价格历史必须按日期递增") }
        guard snapshot.buyMarkers.allSatisfy({ $0.price.isFinite && $0.price > 0 && $0.quantity.isFinite && $0.quantity != 0 && $0.amount.isFinite && $0.amount > 0 && abs($0.amount - $0.price * abs($0.quantity)) <= 0.02 }) else { throw SnapshotStoreError.invalidSnapshot("成交记录金额与价格/数量不一致") }
        if let low = snapshot.quote.dayLow, let high = snapshot.quote.dayHigh {
            guard low.isFinite, high.isFinite, low <= high, snapshot.quote.lastPrice >= low, snapshot.quote.lastPrice <= high else { throw SnapshotStoreError.invalidSnapshot("日内范围无效") }
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: QQQMSnapshot?
    @Published private(set) var confirmation: PlanConfirmation?
    @Published private(set) var loadError: String?
    @Published private(set) var marketError: String?
    @Published private(set) var isRefreshing = false
    @Published var pulse = false
    private let store = SnapshotStore.shared
    private let previewMode: Bool
    private let lastMarketRefreshKey = "QQQMBar.lastSuccessfulMarketRefresh"
    private let marketDataRevisionKey = "QQQMBar.marketDataRevision"
    private let marketDataRevision = "synchronized-market-batch-v3"

    init(
        previewSnapshot: QQQMSnapshot? = nil,
        previewConfirmation: PlanConfirmation? = nil,
        previewMarketError: String? = nil,
        previewLoadError: String? = nil,
        previewIsRefreshing: Bool = false,
        forcePreviewMode: Bool = false
    ) {
        if previewSnapshot != nil || forcePreviewMode {
            previewMode = true
            snapshot = previewSnapshot
            confirmation = previewConfirmation
            loadError = previewLoadError
            marketError = previewMarketError
            isRefreshing = previewIsRefreshing
            return
        }
        previewMode = false
        do {
            try store.prepareInitialSnapshot()
            reload()
        }
        catch { loadError = error.localizedDescription }
    }

    var iconState: GlyphState {
        guard let snapshot else { return .error }
        if marketError != nil || !snapshot.auditIssues.isEmpty || !snapshot.freshnessIssues().isEmpty { return .error }
        if confirmation?.recommendationID == snapshot.recommendation.id { return .confirmed }
        switch snapshot.recommendation.kind {
        case .increase: return .increase
        case .decrease: return .decrease
        case .normal: return .pending
        }
    }
    var planConfirmed: Bool { guard let snapshot else { return false }; return confirmation?.recommendationID == snapshot.recommendation.id }

    func reload() {
        if previewMode { return }
        do { snapshot = try store.load(); confirmation = try store.loadConfirmation(); loadError = nil }
        catch { snapshot = nil; confirmation = nil; loadError = error.localizedDescription }
    }
    @discardableResult
    func refreshMarketDataIfDue(now: Date = Date()) async -> Bool {
        let lastRefresh = UserDefaults.standard.object(forKey: lastMarketRefreshKey) as? Date
        let needsPipelineUpgrade = UserDefaults.standard.string(forKey: marketDataRevisionKey) != marketDataRevision
        let marketDataIsStale = !MarketRefreshSchedule.isFresh(marketDate: snapshot?.priceHistory.last?.date, now: now)
        guard needsPipelineUpgrade || marketDataIsStale || MarketRefreshSchedule.isDue(lastRefresh: lastRefresh, now: now) else { return true }
        return await refreshMarketData(force: true, now: now)
    }
    @discardableResult
    func refreshMarketData(force: Bool = false, now: Date = Date()) async -> Bool {
        guard !previewMode, !isRefreshing, let snapshot else { return false }
        if !force {
            let lastRefresh = UserDefaults.standard.object(forKey: lastMarketRefreshKey) as? Date
            let marketDataIsStale = !MarketRefreshSchedule.isFresh(marketDate: snapshot.priceHistory.last?.date, now: now)
            guard marketDataIsStale || MarketRefreshSchedule.isDue(lastRefresh: lastRefresh, now: now) else { return true }
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let refreshed = try await LiveMarketDataService().refreshedSnapshot(from: snapshot, now: now, confirmedRecommendationID: confirmation?.recommendationID)
            try store.save(refreshed)
            self.snapshot = refreshed
            UserDefaults.standard.set(Date(), forKey: lastMarketRefreshKey)
            UserDefaults.standard.set(marketDataRevision, forKey: marketDataRevisionKey)
            marketError = nil
            loadError = nil
            return true
        } catch {
            marketError = "市场数据刷新失败：\(error.localizedDescription)"
            return false
        }
    }
    func importSnapshot(from url: URL) {
        do { try store.importSnapshot(from: url); reload() }
        catch { loadError = "导入失败：\(error.localizedDescription)" }
    }
    func confirmPlan() {
        guard let snapshot else { return }
        do {
            try store.saveConfirmation(PlanConfirmation(recommendationID: snapshot.recommendation.id, confirmedAt: Date()))
            confirmation = try store.loadConfirmation(); pulse.toggle()
        } catch { loadError = "保存确认失败：\(error.localizedDescription)" }
    }
    func reopenPlan() {
        do { try store.saveConfirmation(nil); confirmation = nil; pulse.toggle() }
        catch { loadError = "重置计划失败：\(error.localizedDescription)" }
    }
    func openDataFolder() { NSWorkspace.shared.activateFileViewerSelecting([store.snapshotURL]) }
}

struct StatusGlyph: View {
    let state: GlyphState
    let pulse: Bool

    var body: some View {
        Text("Q")
            .font(.system(size: 15.5, weight: .semibold, design: .default))
            .frame(width: 18, height: 18)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .normal: "QQQM 正常"
        case .pending: "QQQM 本周计划待确认"
        case .increase: "QQQM 建议加码"
        case .decrease: "QQQM 建议减码"
        case .confirmed: "QQQM 本周计划已确认"
        case .error: "QQQM 数据异常"
        }
    }
}

enum StatusGlyphImage {
    static func make(state: GlyphState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { size in
            let font = NSFont.systemFont(ofSize: 15.2, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let mark = NSAttributedString(string: "Q", attributes: attributes)
            let markSize = mark.size()
            mark.draw(at: NSPoint(x: (size.width - markSize.width) / 2 - 0.15, y: (size.height - markSize.height) / 2 + 0.15))

            return true
        }
        image.isTemplate = true
        return image
    }
}

private func dcaReminderTitle(nextExecution: Date?, confirmed: Bool, hasError: Bool, now: Date = Date()) -> String {
    if hasError { return "!" }
    if confirmed { return "✓" }
    guard let nextExecution else { return "" }
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: nextExecution)).day ?? 0
    switch days {
    case ...(-1): return "逾期"
    case 0: return "今日"
    case 1: return "明日"
    case 2...3: return "\(days)天"
    default: return ""
    }
}

private final class StatusBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum StatusPalette {
    private static func color(_ hex: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    static let accent = adaptive(light: 0x087C84, dark: 0x35C4C7)
    static let positive = adaptive(light: 0x2A8D57, dark: 0x6BC887)
    static let caution = adaptive(light: 0xA36A16, dark: 0xE1A43A)
    static let negative = adaptive(light: 0xB94E48, dark: 0xE9776D)
}

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var outsideMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var marketRefreshTimer: Timer?
    private var snapshotReloadTimer: Timer?
    private var outsideClicksEnabledAfter = TimeInterval.greatestFiniteMagnitude
    private let statusBadge = StatusBadgeView(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseDown])
        statusBadge.wantsLayer = true
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.layer?.cornerRadius = 2
        button.addSubview(statusBadge)
        NSLayoutConstraint.activate([
            statusBadge.widthAnchor.constraint(equalToConstant: 4),
            statusBadge.heightAnchor.constraint(equalToConstant: 4),
            statusBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1.5),
            statusBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 2.5)
        ])
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: DashboardLayout.width, height: DashboardLayout.height)
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView().environmentObject(model))
        updateStatusItem()
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
#if !QQQMBAR_INTERACTION_TEST
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.model.refreshMarketDataIfDue()
            self.scheduleNextMarketRefresh(retrySoon: !succeeded)
            self.scheduleLocalSnapshotReload()
        }
#endif
    }

    private func scheduleLocalSnapshotReload() {
        snapshotReloadTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.reload() }
        }
        snapshotReloadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleNextMarketRefresh(retrySoon: Bool = false) {
        marketRefreshTimer?.invalidate()
        let now = Date()
        let nextRefresh = retrySoon ? (MarketRefreshSchedule.retryDate(after: now) ?? MarketRefreshSchedule.nextRefresh(after: now)) : MarketRefreshSchedule.nextRefresh(after: now)
        let timer = Timer(timeInterval: max(1, nextRefresh.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let succeeded = await self.model.refreshMarketData(force: true)
                self.scheduleNextMarketRefresh(retrySoon: !succeeded)
            }
        }
        marketRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            dismissPopover()
        } else {
            let outsideClicksEnabledAfter = ProcessInfo.processInfo.systemUptime + 0.18
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            configurePopoverWindow()
            startOutsideMouseMonitor(enabledAfter: outsideClicksEnabledAfter)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideMouseMonitor()
    }

    private func configurePopoverWindow() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.level = .statusBar
        // This is a non-activating menu-bar app. Setting this to true makes the
        // panel disappear immediately because the owning app intentionally
        // remains inactive while the popover is open.
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func startOutsideMouseMonitor(enabledAfter: TimeInterval) {
        stopOutsideMouseMonitor()
        outsideClicksEnabledAfter = enabledAfter
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            DispatchQueue.main.async { self?.dismissPopoverForOutsideClick(timestamp: timestamp) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            if event.window !== popoverWindow && ProcessInfo.processInfo.systemUptime >= self.outsideClicksEnabledAfter {
                DispatchQueue.main.async { self.dismissPopover() }
            }
            return event
        }
    }

    private func stopOutsideMouseMonitor() {
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        self.outsideMouseMonitor = nil
        self.localMouseMonitor = nil
        outsideClicksEnabledAfter = .greatestFiniteMagnitude
    }

    private func dismissPopoverForOutsideClick(timestamp: TimeInterval) {
        guard popover.isShown, timestamp >= outsideClicksEnabledAfter else { return }
        dismissPopover()
    }

    private func dismissPopover() {
        guard popover.isShown else { stopOutsideMouseMonitor(); return }
        popover.close()
        stopOutsideMouseMonitor()
    }

#if QQQMBAR_INTERACTION_TEST
    func runInteractionSelfTest() -> Bool {
        guard let button = statusItem?.button else { FileHandle.standardError.write(Data("interaction diagnostics: missing status button\n".utf8)); return false }
        guard popover.behavior == .transient else { FileHandle.standardError.write(Data("interaction diagnostics: popover is not transient\n".utf8)); return false }
        let activeBefore = NSApplication.shared.isActive
        togglePopover(button)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let shown = popover.isShown
        let activeAfter = NSApplication.shared.isActive
        let window = popover.contentViewController?.view.window
        let actuallyVisible = window?.isVisible == true && (window?.alphaValue ?? 0) > 0 && (window?.windowNumber ?? 0) > 0
        let stationary = window?.collectionBehavior.contains(.stationary) == true
        let instant = window?.animationBehavior == NSWindow.AnimationBehavior.none && popover.animates == false
        let remainsVisibleWhileInactive = window?.hidesOnDeactivate == false
        let outsideClickMonitorInstalled = outsideMouseMonitor != nil
        let localClickMonitorInstalled = localMouseMonitor != nil
        let compactStatusItem = statusItem?.length == NSStatusItem.squareLength && button.title.isEmpty
        let clickGate = outsideClicksEnabledAfter
        dismissPopoverForOutsideClick(timestamp: clickGate - 0.01)
        let openingClickIgnored = clickGate.isFinite && popover.isShown
        dismissPopoverForOutsideClick(timestamp: clickGate + 0.01)
        let laterOutsideClickDismissed = !popover.isShown
        if laterOutsideClickDismissed { togglePopover(button); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        dismissPopover()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let dismissed = !popover.isShown
        let diagnostics = "interaction diagnostics: shown=\(shown) actuallyVisible=\(actuallyVisible) dismissed=\(dismissed) stationary=\(stationary) instant=\(instant) remainsVisibleWhileInactive=\(remainsVisibleWhileInactive) outsideMonitor=\(outsideClickMonitorInstalled) localMonitor=\(localClickMonitorInstalled) compactStatusItem=\(compactStatusItem) openingClickIgnored=\(openingClickIgnored) laterOutsideClickDismissed=\(laterOutsideClickDismissed) activeBefore=\(activeBefore) activeAfter=\(activeAfter)\n"
        FileHandle.standardError.write(Data(diagnostics.utf8))
        return shown && actuallyVisible && dismissed && stationary && instant && remainsVisibleWhileInactive && outsideClickMonitorInstalled && localClickMonitorInstalled && compactStatusItem && openingClickIgnored && laterOutsideClickDismissed && activeAfter == activeBefore
    }
#endif

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let reminder = dcaReminderTitle(
            nextExecution: model.snapshot?.recommendation.nextExecution,
            confirmed: model.planConfirmed,
            hasError: model.iconState == .error
        )
        button.image = StatusGlyphImage.make(state: model.iconState)
        button.title = ""
        button.imagePosition = .imageOnly
        statusItem?.length = NSStatusItem.squareLength
        let recommendationColor: NSColor = switch model.snapshot?.recommendation.kind {
        case .increase: StatusPalette.positive
        case .decrease: StatusPalette.caution
        default: StatusPalette.accent
        }
        let reminderBadgeColor: NSColor? = switch reminder {
        case "✓": StatusPalette.positive
        case "今日", "明日", "2天", "3天": recommendationColor
        case "逾期", "!": StatusPalette.negative
        default: nil
        }
        let badgeColor: NSColor? = model.marketError == nil ? reminderBadgeColor : StatusPalette.caution
        statusBadge.layer?.backgroundColor = badgeColor?.cgColor
        statusBadge.isHidden = badgeColor == nil
        var labelParts = [statusLabel(for: model.iconState)]
        if let recommendation = model.snapshot?.recommendation {
            labelParts.append("\(recommendation.kind.label) US$\(Int(recommendation.recommendedAmount))")
        }
        if !reminder.isEmpty { labelParts.append(reminder) }
        if model.marketError != nil { labelParts.append("市场数据更新失败，正在使用上一份有效快照") }
        let label = labelParts.joined(separator: "，")
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func statusLabel(for state: GlyphState) -> String {
        switch state {
        case .normal: "QQQM 正常"
        case .pending: "QQQM 本周计划待确认"
        case .increase: "QQQM 本期建议多投"
        case .decrease: "QQQM 本期建议少投"
        case .confirmed: "QQQM 本周计划已确认"
        case .error: "QQQM 数据异常"
        }
    }
}

private enum DashboardLayout {
    static let width: CGFloat = 356
    static let height: CGFloat = 600
}

private enum TradeDirection: String { case buy, sell }

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private func exponentialMovingAverage(_ points: [PricePoint], period: Int) -> [PricePoint] {
    guard period > 0, let first = points.first else { return [] }
    let smoothing = 2.0 / (Double(period) + 1.0)
    var value = first.close
    return points.enumerated().map { index, point in
        if index > 0 { value = point.close * smoothing + value * (1 - smoothing) }
        return PricePoint(date: point.date, close: value)
    }
}

private enum QDesign {
    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsColor(dark) : nsColor(light)
        })
    }

    // One quiet material family for the whole product. The light and dark
    // values are tuned independently; color is reserved for meaning.
    static let background = adaptive(light: 0xF1F5F6, dark: 0x01080B)
    static let surface = adaptive(light: 0xFCFDFD, dark: 0x071216)
    static let elevated = adaptive(light: 0xFFFFFF, dark: 0x0B171B)
    static let separator = adaptive(light: 0xCFD9DC, dark: 0x1B2C31)
    static let track = adaptive(light: 0xDCE5E8, dark: 0x1B2B30)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = adaptive(light: 0x0B819D, dark: 0x31C3CE)
    static let positive = adaptive(light: 0x318A55, dark: 0x70C88A)
    static let caution = adaptive(light: 0xA86C12, dark: 0xE5A52D)
    static let negative = adaptive(light: 0xBB4B45, dark: 0xEC6F65)
    static let outerRadius: CGFloat = 15
    static let innerRadius: CGFloat = 8
    static let sectionPadding: CGFloat = 10
}

private enum QFormat {
    static func usd(_ amount: Double, decimals: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }

    static func signedUSD(_ amount: Double, decimals: Int = 2) -> String {
        "\(amount >= 0 ? "+" : "−")\(usd(abs(amount), decimals: decimals))"
    }

    static func percent(_ value: Double, decimals: Int = 1, signed: Bool = true) -> String {
        String(format: signed ? "%+.*f%%" : "%.*f%%", decimals, value)
    }
}

private struct QDecisionCanvas<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: QDesign.outerRadius, style: .continuous)
                    .fill(QDesign.surface.opacity(colorScheme == .dark ? 0.93 : 0.98))
            }
            .overlay {
                RoundedRectangle(cornerRadius: QDesign.outerRadius, style: .continuous)
                    .stroke(QDesign.separator.opacity(colorScheme == .dark ? 0.90 : 0.82), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 12, y: 5)
    }
}

private struct QuoteContextStrip: View {
    let periodReturn: Double
    let periodTint: Color
    let costDeviation: Double?
    let valuation: String

    var body: some View {
        HStack(spacing: 0) {
            metric(
                title: "30D",
                value: String(format: "%+.1f%%", periodReturn),
                tint: periodTint
            )
            Divider().frame(height: 20)
            metric(
                title: "相对成本",
                value: costDeviation.map { String(format: "%+.2f%%", $0) } ?? "—",
                tint: (costDeviation ?? 0) < 0 ? QDesign.negative : QDesign.positive
            )
            Divider().frame(height: 20)
            metric(title: "QQQM P/E", value: valuation, tint: QDesign.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(title: String, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(QDesign.tertiary)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CashFlowEquation: View {
    let availableFunds: Double
    let planAmount: Double
    private var remainingFunds: Double { max(0, availableFunds - planAmount) }

    var body: some View {
        HStack(spacing: 7) {
            term("可用资金", availableFunds, tint: QDesign.primary)
            Text("−").foregroundStyle(QDesign.tertiary)
            term("本期计划", planAmount, tint: QDesign.accent)
            Text("=").foregroundStyle(QDesign.tertiary)
            term("计划后可用", remainingFunds, tint: availableFunds >= planAmount ? QDesign.positive : QDesign.caution)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("可用资金减去本期计划，按计划测算剩余 \(QFormat.usd(remainingFunds))")
    }

    private func term(_ title: String, _ amount: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(QDesign.secondary)
            Text(QFormat.usd(amount))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FreshTradeEvent: Identifiable {
    let id: String
    let date: Date
    let price: Double
    let quantity: Double
    let amount: Double
    let direction: TradeDirection
    let ordinal: Int
}

private struct TradeDayExecution: Identifiable {
    let date: Date
    let events: [FreshTradeEvent]
    var id: Date { date }
}

private func marketTradingDayComponents(for date: Date) -> DateComponents {
    var marketCalendar = Calendar(identifier: .gregorian)
    marketCalendar.timeZone = MarketRefreshSchedule.marketTimeZone
    return marketCalendar.dateComponents([.year, .month, .day], from: date)
}

private func marketTradingDayDate(for date: Date) -> Date {
    var chartCalendar = Calendar(identifier: .gregorian)
    chartCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return chartCalendar.date(from: marketTradingDayComponents(for: date)) ?? date
}

private func aggregateTradeValues(_ markers: [BuyMarker]) -> (quantity: Double, price: Double, amount: Double)? {
    guard let first = markers.first else { return nil }
    let quantity = markers.reduce(0) { $0 + abs($1.quantity) }
    let amount = markers.reduce(0) { $0 + abs($1.amount) }
    let weightedPrice = quantity > 0
        ? markers.reduce(0) { $0 + abs($1.quantity) * $1.price } / quantity
        : first.price
    return (quantity, weightedPrice, amount)
}

private func individualTradeEvents(_ snapshot: QQQMSnapshot, within domain: ClosedRange<Date>) -> [FreshTradeEvent] {
    let markers = snapshot.buyMarkers
        .filter { domain.contains(marketTradingDayDate(for: $0.date)) }
        .sorted { $0.date < $1.date }
    var buyOrdinal = 0
    var sellOrdinal = 0
    return markers.map { marker in
        let direction: TradeDirection = marker.quantity < 0 ? .sell : .buy
        if direction == .buy { buyOrdinal += 1 } else { sellOrdinal += 1 }
        return FreshTradeEvent(
            id: marker.id,
            date: marketTradingDayDate(for: marker.date),
            price: marker.price,
            quantity: abs(marker.quantity),
            amount: marker.amount,
            direction: direction,
            ordinal: direction == .buy ? buyOrdinal : sellOrdinal
        )
    }
}

private struct TradeExecutionBand: View {
    let events: [FreshTradeEvent]

    private var dayGroups: [TradeDayExecution] {
        Dictionary(grouping: events, by: \.date)
            .map { TradeDayExecution(date: $0.key, events: $0.value.sorted { $0.ordinal < $1.ordinal }) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(dayGroups) { group in
                VStack(spacing: 1.5) {
                    Text(group.date.formatted(.dateTime.month(.defaultDigits).day()))
                        .foregroundStyle(group.events.allSatisfy { $0.direction == .buy } ? QDesign.positive : QDesign.secondary)
                    ForEach(group.events) { event in
                        Text("\(event.direction == .buy ? "买" : "卖")\(event.ordinal)  $\(event.price, specifier: "%.2f")")
                            .foregroundStyle(event.direction == .buy ? QDesign.secondary : QDesign.negative)
                    }
                }
                .font(.system(size: 7.2, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(group.events.map(executionHelp).joined(separator: "\n"))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(group.events.map(executionHelp).joined(separator: "；"))
            }
        }
        .frame(height: events.isEmpty ? 0 : (dayGroups.contains { $0.events.count > 1 } ? 36 : 26))
    }

    private func executionHelp(_ event: FreshTradeEvent) -> String {
        let side = event.direction == .buy ? "买入" : "卖出"
        return "\(event.date.formatted(.dateTime.year().month().day())) · \(side)\(event.ordinal) · 成交价 $\(String(format: "%.2f", event.price))/股 · \(String(format: "%.4f", event.quantity)) 股 · 金额 $\(String(format: "%.2f", event.amount))"
    }
}

private struct DecisionPriceChart: View {
    let snapshot: QQQMSnapshot
    @State private var selectedDate: Date?

    private var ema20: [PricePoint] { exponentialMovingAverage(snapshot.priceHistory, period: 20) }
    private var dateDomain: ClosedRange<Date> {
        guard let first = snapshot.priceHistory.first?.date, let last = snapshot.priceHistory.last?.date else { return Date()...Date() }
        return first...last
    }
    private var yDomain: ClosedRange<Double> {
        let values = snapshot.priceHistory.map(\.close) + ema20.map(\.close) + tradeEvents.map(\.price)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.12, high * 0.004)
        return (low - padding)...(high + padding)
    }
    private var selectedPoint: PricePoint? {
        guard let selectedDate else { return nil }
        return snapshot.priceHistory.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var tradeEvents: [FreshTradeEvent] { individualTradeEvents(snapshot, within: dateDomain) }
    private var middleDate: Date? {
        guard !snapshot.priceHistory.isEmpty else { return nil }
        return snapshot.priceHistory[snapshot.priceHistory.count / 2].date
    }
    private var selectedExecutions: [FreshTradeEvent] {
        guard let selectedPoint else { return [] }
        return tradeEvents.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedPoint.date) }
    }

    var body: some View {
        VStack(spacing: 1) {
            Chart {
            ForEach(snapshot.priceHistory) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    yStart: .value("基线", yDomain.lowerBound),
                    yEnd: .value("价格", point.close)
                )
                .foregroundStyle(LinearGradient(colors: [QDesign.accent.opacity(0.16), QDesign.accent.opacity(0.008)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)

                LineMark(x: .value("日期", point.date), y: .value("价格", point.close), series: .value("系列", "QQQM"))
                    .foregroundStyle(QDesign.accent)
                    .lineStyle(.init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(ema20) { point in
                LineMark(x: .value("日期", point.date), y: .value("EMA20", point.close), series: .value("系列", "EMA20"))
                    .foregroundStyle(QDesign.secondary.opacity(0.66))
                    .lineStyle(.init(lineWidth: 0.85, lineCap: .round, dash: [3, 3]))
                    .interpolationMethod(.catmullRom)
            }
                if snapshot.portfolio.averageCost > 0 {
                    RuleMark(y: .value("平均成本", snapshot.portfolio.averageCost))
                        .foregroundStyle(QDesign.caution.opacity(0.74))
                        .lineStyle(.init(lineWidth: 0.85, dash: [5, 3]))
                }
            ForEach(tradeEvents) { event in
                RuleMark(
                    x: .value("成交日", event.date),
                    yStart: .value("图表底部", yDomain.lowerBound),
                    yEnd: .value("成交价", event.price)
                )
                .foregroundStyle((event.direction == .buy ? QDesign.positive : QDesign.negative).opacity(0.48))
                .lineStyle(.init(lineWidth: 0.65, dash: [1.5, 2]))
            }
            if let selectedPoint {
                RuleMark(x: .value("选中日期", selectedPoint.date))
                    .foregroundStyle(QDesign.secondary.opacity(0.42))
                    .lineStyle(.init(lineWidth: 0.65, dash: [2, 2]))
                PointMark(x: .value("选中日期", selectedPoint.date), y: .value("选中价格", selectedPoint.close))
                    .foregroundStyle(QDesign.primary)
                    .symbolSize(22)
                    .annotation(position: .top, spacing: 4) {
                        selectionPopover(selectedPoint)
                    }
            }
        }
            .chartXScale(domain: dateDomain)
            .chartYScale(domain: yDomain)
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.45, dash: [2, 3]))
                        .foregroundStyle(QDesign.separator.opacity(0.44))
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text("\(price, specifier: "%.0f")")
                        }
                    }
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(QDesign.tertiary)
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 108)

            HStack {
                Text(snapshot.priceHistory.first?.date ?? snapshot.lastUpdated, format: .dateTime.month(.defaultDigits).day())
                Spacer()
                Text(middleDate ?? snapshot.lastUpdated, format: .dateTime.month(.defaultDigits).day())
                Spacer()
                Text(snapshot.priceHistory.last?.date ?? snapshot.lastUpdated, format: .dateTime.month(.defaultDigits).day())
            }
            .font(.system(size: 7.5, weight: .medium, design: .rounded))
            .foregroundStyle(QDesign.secondary)
            .padding(.trailing, 24)

            TradeExecutionBand(events: tradeEvents)
                .padding(.trailing, 24)
        }
        .accessibilityLabel("QQQM 最近三十个交易日收盘价、二十日指数均线与真实买卖成交价")
    }

    @ViewBuilder
    private func selectionPopover(_ point: PricePoint) -> some View {
        VStack(spacing: 1) {
            Text("\(point.date.formatted(.dateTime.month(.defaultDigits).day()))  $\(point.close, specifier: "%.2f")")
            ForEach(selectedExecutions) { event in
                Text("\(event.direction == .buy ? "买" : "卖")\(event.ordinal) · $\(event.price, specifier: "%.2f")/股 · \(event.quantity, specifier: "%.4f") 股 · 共 $\(event.amount, specifier: "%.2f")")
                    .foregroundStyle(event.direction == .buy ? QDesign.positive : QDesign.negative)
            }
        }
        .font(.system(size: 8, weight: .medium, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct EvidenceChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(title).foregroundStyle(QDesign.secondary)
            }
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(QDesign.primary)
                .lineLimit(1).minimumScaleFactor(0.78)
        }
        .font(.system(size: 9, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AllocationStepScale: View {
    let selectedAmount: Double
    private let amounts = [200.0, 300.0, 400.0, 500.0, 600.0]

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Rectangle().fill(QDesign.separator.opacity(0.72)).frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(amounts, id: \.self) { amount in
                        let selected = abs(amount - selectedAmount) < 0.1
                        Capsule()
                            .fill(selected ? QDesign.accent : QDesign.secondary.opacity(0.62))
                            .frame(width: selected ? 3 : 1, height: selected ? 12 : 6)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(amounts, id: \.self) { amount in
                    Text("$\(Int(amount))")
                        .font(.system(size: 8.5, weight: abs(amount - selectedAmount) < 0.1 ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(abs(amount - selectedAmount) < 0.1 ? QDesign.accent : QDesign.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityLabel("定投五档金额，当前选择 \(selectedAmount, specifier: "%.0f") 美元")
    }
}

private struct FactorConditionRow: View {
    let title: String
    let value: String
    let source: String
    let position: Double
    let status: String
    let tint: Color
    let lowerBoundary: Double
    let upperBoundary: Double

    private var clamped: Double { min(max(position, 0), 1) }
    private var lowBoundary: Double { min(max(lowerBoundary, 0.08), 0.84) }
    private var highBoundary: Double { min(max(upperBoundary, lowBoundary + 0.08), 0.92) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9, weight: .medium))
                Text(source).font(.system(size: 7.5)).foregroundStyle(QDesign.tertiary).lineLimit(1)
            }
            .frame(width: 72, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(QDesign.track).frame(height: 2)
                    Rectangle().fill(QDesign.separator).frame(width: 1, height: 7)
                        .offset(x: proxy.size.width * lowBoundary)
                    Rectangle().fill(QDesign.separator).frame(width: 1, height: 7)
                        .offset(x: proxy.size.width * highBoundary)
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .offset(x: max(0, min(proxy.size.width - 7, proxy.size.width * clamped - 3.5)))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)

            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(status).font(.system(size: 7.5, weight: .medium)).foregroundStyle(tint)
            }
            .frame(width: 66, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CompactFactorMetric: View {
    let title: String
    let value: String
    let status: String
    let position: Double
    let tint: Color
    let lowerBoundary: Double
    let upperBoundary: Double

    private var clamped: Double { min(max(position, 0), 1) }
    private var lowBoundary: Double { min(max(lowerBoundary, 0.08), 0.84) }
    private var highBoundary: Double { min(max(upperBoundary, lowBoundary + 0.08), 0.92) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).foregroundStyle(QDesign.secondary)
                Spacer(minLength: 2)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(QDesign.primary)
                    .monospacedDigit()
            }
            .font(.system(size: 8, weight: .medium))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(QDesign.track).frame(height: 3)
                    Capsule()
                        .fill(tint.opacity(0.22))
                        .frame(width: proxy.size.width * (highBoundary - lowBoundary), height: 3)
                        .offset(x: proxy.size.width * lowBoundary)
                    ForEach([lowBoundary, highBoundary], id: \.self) { boundary in
                        Rectangle().fill(QDesign.separator).frame(width: 1, height: 7)
                            .offset(x: max(0, proxy.size.width * boundary - 0.5))
                    }
                    Rectangle().fill(tint).frame(width: 1.5, height: 10)
                        .offset(x: max(0, min(proxy.size.width - 1.5, proxy.size.width * clamped - 0.75)))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)

            HStack {
                Text("低")
                Spacer()
                Text(status).foregroundStyle(tint)
                Spacer()
                Text("高")
            }
            .font(.system(size: 6.8, weight: .medium))
            .foregroundStyle(QDesign.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)，\(status)")
    }
}

private struct LocalPriceRail: View {
    let currentPrice: Double
    let averageCost: Double

    private var displayedCurrentPrice: Double { (currentPrice * 100).rounded() / 100 }
    private var displayedAverageCost: Double { (averageCost * 100).rounded() / 100 }

    private var lowerBound: Double {
        floor((min(displayedCurrentPrice, displayedAverageCost) - 0.20) * 20) / 20
    }
    private var upperBound: Double {
        let candidate = ceil(((max(displayedCurrentPrice, displayedAverageCost) + 0.15) * 20) - 0.000_001) / 20
        return max(candidate, lowerBound + 0.20)
    }
    private func position(_ value: Double) -> Double {
        min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("局部价差").font(.system(size: 8.5, weight: .semibold))
                Spacer()
                Text("$\(lowerBound, specifier: "%.2f")—$\(upperBound, specifier: "%.2f")")
                    .font(.system(size: 7.5, design: .rounded))
                    .foregroundStyle(QDesign.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(QDesign.track).frame(height: 3)
                    ForEach(1..<4, id: \.self) { index in
                        Rectangle().fill(QDesign.separator).frame(width: 1, height: 7)
                            .offset(x: proxy.size.width * CGFloat(index) / 4)
                    }
                    Rectangle().fill(QDesign.accent).frame(width: 1.5, height: 10)
                        .offset(x: proxy.size.width * position(displayedCurrentPrice) - 0.75)
                    Rectangle().fill(QDesign.caution).frame(width: 1.5, height: 10)
                        .offset(x: proxy.size.width * position(displayedAverageCost) - 0.75)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            HStack {
                Text("现价 $\(displayedCurrentPrice, specifier: "%.2f")").foregroundStyle(QDesign.accent)
                Spacer()
                Text("成本 $\(displayedAverageCost, specifier: "%.2f")").foregroundStyle(QDesign.caution)
            }
            .font(.system(size: 7.5, weight: .medium, design: .rounded))
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("局部价差，现价 \(displayedCurrentPrice, specifier: "%.2f") 美元，成本 \(displayedAverageCost, specifier: "%.2f") 美元")
    }
}

private struct TierTransitionView: View {
    let moreDetail: String
    let lessDetail: String
    let moreReached: Bool
    let lessReached: Bool

    var body: some View {
        HStack(spacing: 0) {
            transition(
                amount: "$500",
                title: moreReached ? "升档条件已满足" : "升档还差",
                logic: "任一项",
                detail: moreDetail,
                tint: QDesign.positive
            )
            Divider().padding(.vertical, 1)
            transition(
                amount: "$300",
                title: lessReached ? "降档条件已满足" : "降档还缺",
                logic: "全部项",
                detail: lessDetail,
                tint: QDesign.caution
            )
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(QDesign.separator.opacity(0.55)).frame(height: 0.5)
        }
    }

    private func transition(amount: String, title: String, logic: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(amount)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                Text(title).font(.system(size: 8.5, weight: .medium))
                Spacer(minLength: 2)
                Text(logic)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(detail)
                .font(.system(size: 7.5, design: .rounded))
                .foregroundStyle(QDesign.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct FundsCoverageRail: View {
    let availableFunds: Double
    let planAmount: Double
    private var coverage: Double { planAmount > 0 ? max(0, availableFunds / planAmount) : 0 }
    private var remainingFunds: Double { max(0, availableFunds - planAmount) }
    private var remainingCoverage: Double { planAmount > 0 ? remainingFunds / planAmount : 0 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(QDesign.track).frame(height: 3)
                    Capsule().fill(QDesign.positive.opacity(0.72))
                        .frame(width: proxy.size.width * min(coverage / 4, 1))
                    Capsule().fill(QDesign.accent)
                        .frame(width: proxy.size.width * min(min(coverage, 1) / 4, 1))
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { _ in
                            Spacer()
                            Rectangle().fill(QDesign.separator).frame(width: 1, height: 7)
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 8)
            HStack {
                if availableFunds >= planAmount {
                    Text("本期预留 \(QFormat.usd(planAmount)) · 剩余 \(QFormat.usd(remainingFunds))")
                } else {
                    Text("本期资金缺口 \(QFormat.usd(planAmount - availableFunds))")
                        .foregroundStyle(QDesign.caution)
                }
                Spacer()
                Text("后续 \(remainingCoverage, specifier: "%.1f") 期")
            }
            .font(.system(size: 8, design: .rounded)).foregroundStyle(QDesign.secondary)
        }
        .accessibilityLabel("可用资金共覆盖 \(coverage, specifier: "%.1f") 期；预留本期后还可覆盖 \(remainingCoverage, specifier: "%.1f") 期")
    }
}

private struct ThresholdRuleRow: View {
    let amount: String
    let title: String
    let logic: String
    let conditions: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(amount)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 8.5, weight: .medium))
                    Text(logic).font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.10), in: Capsule())
                }
                Text(conditions).font(.system(size: 7.5)).foregroundStyle(QDesign.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuPopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    init(initialRuleDisclosure: Bool = false) {
        _ = initialRuleDisclosure
    }

    var body: some View {
        Group {
            if let snapshot = model.snapshot { content(snapshot) }
            else { unavailable }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: DashboardLayout.width, height: DashboardLayout.height, alignment: .top)
        .background {
            ZStack {
                QDesign.background
                Rectangle().fill(.ultraThinMaterial)
                RadialGradient(
                    colors: [QDesign.accent.opacity(colorScheme == .dark ? 0.075 : 0.045), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 320
                )
            }
        }
        .foregroundStyle(QDesign.primary)
        .onAppear { model.reload() }
    }

    private func content(_ snapshot: QQQMSnapshot) -> some View {
        decisionDocument(snapshot)
    }

    private func decisionDocument(_ snapshot: QQQMSnapshot) -> some View {
        QDecisionCanvas {
            VStack(spacing: 0) {
                decisionHeader(snapshot)
                sectionDivider
                marketPanel(snapshot)
                sectionDivider
                evidencePanel(snapshot)
                sectionDivider
                portfolioPanel(snapshot)
                sectionDivider
                footer(snapshot)
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(QDesign.separator.opacity(0.60))
            .frame(height: 0.45)
            .padding(.horizontal, QDesign.sectionPadding)
    }

    private func decisionHeader(_ snapshot: QQQMSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本周投入")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(QDesign.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(usd(snapshot.recommendation.recommendedAmount))
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("\(snapshot.recommendation.multiplier, specifier: "%.2f")×")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(recommendationTint(snapshot.recommendation.kind))
                    statusPill(snapshot)
                        .padding(.leading, 2)
                }
            }
            Spacer()
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(executionLabel(snapshot.recommendation.nextExecution))
                        .font(.system(size: 10, weight: .medium))
                    Text(snapshot.recommendation.nextExecution, format: .dateTime.month(.defaultDigits).day().weekday(.abbreviated))
                        .font(.system(size: 8.5)).foregroundStyle(QDesign.secondary)
                }
#if QQQMBAR_RENDER_TEST
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 16, height: 22)
#else
                Menu {
                    Button("立即刷新市场数据") { Task { await model.refreshMarketData(force: true) } }
                    if model.planConfirmed { Button("重新打开本期计划") { model.reopenPlan() } }
                    Button("打开数据文件夹") { model.openDataFolder() }
                    SettingsLink { Text("设置") }
                    Divider()
                    Button("退出 QQQMBar") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 16, height: 22)
                }
                .menuStyle(.borderlessButton)
#endif
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func marketPanel(_ snapshot: QQQMSnapshot) -> some View {
        VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("QQQM · 市场位置")
                            .font(.system(size: 13, weight: .semibold))
                        Text("近 30 个交易日")
                            .font(.system(size: 9)).foregroundStyle(QDesign.secondary)
                    }
                    Spacer()
                    Text(usd(snapshot.quote.lastPrice, decimals: 2))
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(snapshot.quote.dayChangePct / 100, format: .percent.precision(.fractionLength(2)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(snapshot.quote.dayChangePct >= 0 ? QDesign.positive : QDesign.negative)
                }
                QuoteContextStrip(
                    periodReturn: periodReturn(snapshot),
                    periodTint: trendTint(snapshot),
                    costDeviation: costDeviation(snapshot),
                    valuation: signal(snapshot, 3).value
                )
                DecisionPriceChart(snapshot: snapshot)
                HStack(spacing: 10) {
                    chartLegend(color: QDesign.accent, label: "收盘价")
                    chartLegend(color: QDesign.secondary, label: "EMA20", dashed: true)
                    chartLegend(color: QDesign.caution, label: "成本 \(usd(snapshot.portfolio.averageCost, decimals: 2))", dashed: true)
                    Spacer()
                    tradeCount(.buy, count: snapshot.buyMarkers.filter { $0.quantity > 0 }.count)
                    tradeCount(.sell, count: snapshot.buyMarkers.filter { $0.quantity < 0 }.count)
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func evidencePanel(_ snapshot: QQQMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("本期依据")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        Text("多投 OR \(moreTriggerCount(snapshot))/3")
                            .foregroundStyle(moreTriggerCount(snapshot) > 0 ? QDesign.positive : QDesign.secondary)
                        Text("·")
                        Text("少投 AND \(lessTriggerCount(snapshot))/3")
                            .foregroundStyle(lessTriggerCount(snapshot) == 3 ? QDesign.caution : QDesign.secondary)
                    }
                    .font(.system(size: 7.5, weight: .medium)).foregroundStyle(QDesign.secondary)
                }
                HStack(alignment: .top, spacing: 10) {
                    CompactFactorMetric(
                    title: "趋势",
                    value: signal(snapshot, 0).value,
                    status: trendStatus(snapshot),
                    position: trendPosition(snapshot),
                    tint: trendTint(snapshot),
                    lowerBoundary: 0.20,
                    upperBoundary: 0.72
                )
                    CompactFactorMetric(
                    title: "VIX",
                    value: signal(snapshot, 1).value,
                    status: vixStatus(snapshot),
                    position: vixPosition(snapshot),
                    tint: vixTint(snapshot),
                    lowerBoundary: 4.0 / 14.0,
                    upperBoundary: 7.0 / 14.0
                )
                    CompactFactorMetric(
                    title: "CNN",
                    value: String(format: "%.1f", sentimentValue(snapshot)),
                    status: sentimentStatus(snapshot),
                    position: sentimentPosition(snapshot),
                    tint: sentimentTint(snapshot),
                    lowerBoundary: 0.30,
                    upperBoundary: 0.80
                )
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func portfolioPanel(_ snapshot: QQQMSnapshot) -> some View {
        VStack(spacing: 6) {
                HStack {
                    Text("账户与执行").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    if snapshot.source.accountSource != nil {
                        let accountFresh = !snapshot.freshnessIssues().contains(where: { $0.contains("IBKR") })
                        Label(accountFresh ? "IBKR 只读" : "IBKR 待同步", systemImage: accountFresh ? "checkmark.shield.fill" : "clock.badge.exclamationmark")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(accountFresh ? QDesign.positive : QDesign.caution)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.4f 股 QQQM", snapshot.portfolio.shares))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text("市值 \(usd(snapshot.verifiedMarketValue))")
                            .font(.system(size: 8)).foregroundStyle(QDesign.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(costRelationship(snapshot))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(costRelationshipTint(snapshot))
                        Text("未实现 \(signedUSD(snapshot.verifiedUnrealizedPnL)) · \(percent(unrealizedPercent(snapshot)))")
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(snapshot.verifiedUnrealizedPnL >= 0 ? QDesign.positive : QDesign.negative)
                    }
                }
                LocalPriceRail(currentPrice: snapshot.quote.lastPrice, averageCost: snapshot.portfolio.averageCost)
                CashFlowEquation(
                    availableFunds: snapshot.portfolio.availableFunds,
                    planAmount: snapshot.recommendation.recommendedAmount
                )
                FundsCoverageRail(availableFunds: snapshot.portfolio.availableFunds, planAmount: snapshot.recommendation.recommendedAmount)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footer(_ snapshot: QQQMSnapshot) -> some View {
        let status = dataStatus(snapshot)
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: status.icon).foregroundStyle(status.tint)
                Text(status.title)
            }
            .font(.system(size: 8.5, weight: .medium))
            .help(model.marketError ?? status.detail)
            Spacer()
            if model.planConfirmed {
                Label("本期已确认", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QDesign.positive)
                    .frame(width: 154, height: 32)
                    .background(QDesign.positive.opacity(0.09), in: RoundedRectangle(cornerRadius: QDesign.innerRadius, style: .continuous))
            } else {
                Button { model.confirmPlan() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("确认计划 \(usd(snapshot.recommendation.recommendedAmount))")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QDesign.accent)
                    .frame(width: 154, height: 32)
                    .background(QDesign.accent.opacity(colorScheme == .dark ? 0.10 : 0.08), in: RoundedRectangle(cornerRadius: QDesign.innerRadius, style: .continuous))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
                .help("仅保存本地确认记录，不会创建或提交交易订单。")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func dataStatus(_ snapshot: QQQMSnapshot) -> (icon: String, title: String, detail: String, tint: Color) {
        let sourceDates = "行情 \(shortDate(snapshot.source.asOf)) · 账户 \(shortDate(snapshot.source.accountAsOf ?? snapshot.source.asOf))"
        let freshnessIssues = snapshot.freshnessIssues()
        if model.isRefreshing {
            return ("arrow.triangle.2.circlepath", "正在更新市场数据", "上一份快照仍可安全使用", QDesign.accent)
        }
        if model.marketError != nil {
            return ("arrow.clockwise.circle.fill", "更新失败 · 已保留有效快照", sourceDates, QDesign.caution)
        }
        if !snapshot.auditIssues.isEmpty {
            return ("exclamationmark.triangle.fill", "数据校验发现差异", "\(snapshot.auditIssues.count) 项需检查 · \(sourceDates)", QDesign.caution)
        }
        if !freshnessIssues.isEmpty {
            let onlyAccountPending = freshnessIssues.allSatisfy { $0.contains("IBKR") }
            return ("clock.badge.exclamationmark", onlyAccountPending ? "市场已更新 · 账户待同步" : "部分数据待同步", freshnessIssues.joined(separator: "；"), QDesign.caution)
        }
        return ("checkmark.seal.fill", "数据已校验", sourceDates, QDesign.positive)
    }

    private func statusPill(_ snapshot: QQQMSnapshot) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.planConfirmed ? QDesign.positive : recommendationTint(snapshot.recommendation.kind))
                .frame(width: 5, height: 5)
            Text(model.planConfirmed ? "已确认" : snapshot.recommendation.kind.label)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(model.planConfirmed ? QDesign.positive : recommendationTint(snapshot.recommendation.kind))
    }

    private func chartLegend(color: Color, label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: dashed ? 4 : 12, height: 2)
            if dashed { Capsule().fill(color).frame(width: 4, height: 2) }
            Text(label).foregroundStyle(QDesign.secondary)
        }
    }

    private func tradeCount(_ direction: TradeDirection, count: Int) -> some View {
        Text("\(direction == .buy ? "买入" : "卖出") \(count)")
            .foregroundStyle(count == 0 ? QDesign.tertiary : (direction == .buy ? QDesign.positive : QDesign.negative))
        .accessibilityLabel("\(direction == .buy ? "买入" : "卖出") \(count) 笔")
    }

    private func signal(_ snapshot: QQQMSnapshot, _ index: Int) -> MarketSignal {
        guard snapshot.signals.indices.contains(index) else {
            return MarketSignal(id: "missing-\(index)", title: "数据", value: "—", normalized: nil, source: "不可用", asOf: snapshot.lastUpdated, mode: snapshot.source.mode)
        }
        return snapshot.signals[index]
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(QDesign.caution)
            Text("数据暂不可用").font(.headline)
            Text(model.loadError ?? "请在设置中导入有效的 QQQM 快照。")
                .font(.caption).foregroundStyle(QDesign.secondary).multilineTextAlignment(.center)
            Button("重新读取") { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recommendationTint(_ kind: RecommendationKind) -> Color {
        switch kind { case .increase: QDesign.positive; case .decrease: QDesign.caution; case .normal: QDesign.accent }
    }
    private func executionLabel(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0
        return switch days { case ...(-1): "已到期"; case 0: "今天执行"; case 1: "明天执行"; default: "\(days) 天后" }
    }
    private var standardTrendThresholds: String { "≤\(signedPercent(DCAThresholds.moreMomentum)) / ≥\(signedPercent(DCAThresholds.lessMomentum))" }
    private var standardVIXThresholds: String { "≥\(whole(DCAThresholds.moreVIX)) / <\(whole(DCAThresholds.lessVIX))" }
    private var standardSentimentThresholds: String { "<\(whole(DCAThresholds.moreSentiment)) / ≥\(whole(DCAThresholds.lessSentiment))" }
    private var strongMoreConditions: String { "趋势 ≤\(signedPercent(DCAThresholds.strongMoreMomentum)) · CNN ≤\(whole(DCAThresholds.strongMoreSentiment)) · VIX ≥\(whole(DCAThresholds.strongMoreVIX))" }
    private var moreConditions: String { "趋势 ≤\(signedPercent(DCAThresholds.moreMomentum)) · CNN <\(whole(DCAThresholds.moreSentiment)) · VIX ≥\(whole(DCAThresholds.moreVIX))" }
    private var lessConditions: String { "趋势 ≥\(signedPercent(DCAThresholds.lessMomentum)) · CNN ≥\(whole(DCAThresholds.lessSentiment)) · VIX <\(whole(DCAThresholds.lessVIX))" }
    private var strongLessConditions: String { "趋势 ≥\(signedPercent(DCAThresholds.strongLessMomentum)) · CNN ≥\(whole(DCAThresholds.strongLessSentiment)) · VIX <\(whole(DCAThresholds.strongLessVIX))" }
    private func whole(_ value: Double) -> String { String(format: "%.0f", value) }
    private func signedPercent(_ value: Double) -> String { "\(value >= 0 ? "+" : "−")\(whole(abs(value)))%" }
    private func decisionSummary(_ snapshot: QQQMSnapshot) -> String {
        if moreTriggerCount(snapshot) == 0 && lessTriggerCount(snapshot) < 3 {
            let satisfied = satisfiedLessFactors(snapshot)
            let suffix = satisfied.isEmpty ? "降档条件尚未满足" : "降档仅满足\(satisfied.joined(separator: "、"))"
            return "升档 0/3；\(suffix)，本期维持 \(String(format: "%.2f", snapshot.recommendation.multiplier))× 基准。"
        }
        return "趋势 \(signal(snapshot, 0).value) · VIX \(signal(snapshot, 1).value) · 情绪 \(signal(snapshot, 2).value)，本期采用 \(String(format: "%.2f", snapshot.recommendation.multiplier))× 基准。"
    }
    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: "America/New_York"); formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
    private func moreTriggerCount(_ snapshot: QQQMSnapshot) -> Int {
        ruleAudit(snapshot).moreCount
    }
    private func lessTriggerCount(_ snapshot: QQQMSnapshot) -> Int {
        ruleAudit(snapshot).lessCount
    }
    private func ruleAudit(_ snapshot: QQQMSnapshot) -> DCAConditionAudit {
        DCAConditionAudit(momentum: periodReturn(snapshot), vix: vixValue(snapshot), sentiment: sentimentValue(snapshot))
    }
    private func moreTransitionDetail(_ snapshot: QQQMSnapshot) -> String {
        let audit = ruleAudit(snapshot)
        if audit.moreCount > 0 {
            return triggeredFactors(audit.moreChecks).joined(separator: " · ") + " 已触发"
        }
        return "趋势 ↓\(oneDecimal(audit.moreGaps[0]))pp · CNN ↓\(oneDecimal(audit.moreGaps[1])) · VIX ↑\(oneDecimal(audit.moreGaps[2]))"
    }
    private func lessTransitionDetail(_ snapshot: QQQMSnapshot) -> String {
        let audit = ruleAudit(snapshot)
        if audit.lessCount == 3 { return "趋势 · CNN · VIX 已全部满足" }
        var parts: [String] = []
        if audit.lessChecks[0] { parts.append("趋势 ✓") } else { parts.append("趋势 ↑\(oneDecimal(audit.lessGaps[0]))pp") }
        if audit.lessChecks[1] { parts.append("CNN ✓") } else { parts.append("CNN ↑\(oneDecimal(audit.lessGaps[1]))") }
        if audit.lessChecks[2] { parts.append("VIX ✓") } else { parts.append("VIX ↓\(oneDecimal(audit.lessGaps[2]))") }
        return parts.joined(separator: " · ")
    }
    private func triggeredFactors(_ checks: [Bool]) -> [String] {
        let names = ["趋势", "CNN", "VIX"]
        return checks.enumerated().compactMap { $0.element ? names[$0.offset] : nil }
    }
    private func satisfiedLessFactors(_ snapshot: QQQMSnapshot) -> [String] {
        triggeredFactors(ruleAudit(snapshot).lessChecks)
    }
    private func oneDecimal(_ value: Double) -> String {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.05 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
    private func periodReturn(_ snapshot: QQQMSnapshot) -> Double {
        guard let first = snapshot.priceHistory.first?.close, let last = snapshot.priceHistory.last?.close, first > 0 else { return 0 }
        return (last / first - 1) * 100
    }
    private func number(in text: String) -> Double? {
        let filtered = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(filtered)
    }
    private func trendPosition(_ snapshot: QQQMSnapshot) -> Double { min(max((periodReturn(snapshot) + 10) / 25, 0), 1) }
    private func trendStatus(_ snapshot: QQQMSnapshot) -> String {
        switch periodReturn(snapshot) { case ...(-10): "明显回撤"; case ..<(-5): "回撤区间"; case 15...: "强势区间"; case 8...: "偏强区间"; default: "中性区间" }
    }
    private func trendTint(_ snapshot: QQQMSnapshot) -> Color {
        let value = periodReturn(snapshot)
        return value <= -5 ? QDesign.positive : (value >= 8 ? QDesign.caution : QDesign.accent)
    }
    private func vixValue(_ snapshot: QQQMSnapshot) -> Double { number(in: signal(snapshot, 1).value) ?? 22 }
    private func vixPosition(_ snapshot: QQQMSnapshot) -> Double { min(max((vixValue(snapshot) - 18) / 14, 0), 1) }
    private func vixStatus(_ snapshot: QQQMSnapshot) -> String {
        switch vixValue(snapshot) { case 32...: "高波动"; case 25...: "偏高波动"; case ..<18: "低波动"; case ..<22: "温和波动"; default: "中性区间" }
    }
    private func vixTint(_ snapshot: QQQMSnapshot) -> Color {
        let value = vixValue(snapshot)
        return value >= 25 ? QDesign.positive : (value < 22 ? QDesign.caution : QDesign.accent)
    }
    private func sentimentValue(_ snapshot: QQQMSnapshot) -> Double { (signal(snapshot, 2).normalized ?? 0.5) * 100 }
    private func sentimentPosition(_ snapshot: QQQMSnapshot) -> Double { min(max((sentimentValue(snapshot) - 25) / 50, 0), 1) }
    private func sentimentStatus(_ snapshot: QQQMSnapshot) -> String {
        switch sentimentValue(snapshot) { case ...25: "极度恐惧"; case ..<40: "偏恐惧"; case 75...: "偏贪婪"; case 65...: "情绪偏热"; default: "中性区间" }
    }
    private func sentimentTint(_ snapshot: QQQMSnapshot) -> Color {
        let value = sentimentValue(snapshot)
        return value < 40 ? QDesign.positive : (value >= 65 ? QDesign.caution : QDesign.accent)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%+.2f%%", $0) } ?? "—" }
    private func unrealizedPercent(_ snapshot: QQQMSnapshot) -> Double? {
        let basis = snapshot.portfolio.averageCost * snapshot.portfolio.shares
        return basis > 0 ? snapshot.verifiedUnrealizedPnL / basis * 100 : nil
    }
    private func costDeviation(_ snapshot: QQQMSnapshot) -> Double? {
        guard snapshot.portfolio.averageCost > 0 else { return nil }
        return (snapshot.quote.lastPrice / snapshot.portfolio.averageCost - 1) * 100
    }
    private func costRelationship(_ snapshot: QQQMSnapshot) -> String {
        let delta = snapshot.quote.lastPrice - snapshot.portfolio.averageCost
        if abs(delta) < 0.005 { return "接近成本" }
        return "\(delta > 0 ? "高于成本" : "低于成本") \(usd(abs(delta), decimals: 2))"
    }
    private func costRelationshipTint(_ snapshot: QQQMSnapshot) -> Color {
        snapshot.quote.lastPrice >= snapshot.portfolio.averageCost ? QDesign.positive : QDesign.negative
    }
    private func usd(_ amount: Double, decimals: Int = 0) -> String {
        QFormat.usd(amount, decimals: decimals)
    }
    private func signedUSD(_ amount: Double) -> String { QFormat.signedUSD(amount) }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published var message: String?
    func setEnabled(_ value: Bool) {
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; enabled = SMAppService.mainApp.status == .enabled; message = nil }
        catch { enabled = SMAppService.mainApp.status == .enabled; message = error.localizedDescription }
    }
}

private struct SettingsScrollContainer<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: Content

    init(enabled: Bool, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if enabled {
            ScrollView { content }.scrollIndicators(.hidden)
        } else {
            content
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var login = LoginItemController()
    @State private var importing = false
    private let staticPreview: Bool

    init(staticPreview: Bool = false) {
        self.staticPreview = staticPreview
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider().overlay(QDesign.separator)
            SettingsScrollContainer(enabled: !staticPreview) {
                VStack(spacing: 12) {
                    settingsSection("运行方式", icon: "menubar.rectangle") {
                    Toggle("登录后自动启动", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                    if let message = login.message { statusCallout(message, tint: QDesign.negative, icon: "xmark.circle.fill") }
                    }

                    settingsSection("数据与同步", icon: "externaldrive.badge.icloud") {
                        settingsValueRow("状态", dataState.title, valueTint: dataState.tint)
                        settingsValueRow("当前数据", model.snapshot?.source.mode.label ?? "不可用")
                        settingsValueRow("更新时间", model.snapshot?.lastUpdated.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        settingsValueRow("自动刷新", "美股收盘后 15 分钟 · 每日一次")
                        settingsValueRow("账户来源", model.snapshot?.source.accountSource ?? "本地快照")
                        if let accountAsOf = model.snapshot?.source.accountAsOf {
                            settingsValueRow("账户同步", accountAsOf.formatted(date: .abbreviated, time: .shortened))
                        }
                        settingsValueRow("内部校验", model.snapshot.map { $0.auditIssues.isEmpty ? "通过" : "\($0.auditIssues.count) 项差异" } ?? "不可用")
                        if let notes = model.snapshot?.source.notes { Text(notes).font(.caption).foregroundStyle(QDesign.secondary) }
                        if let error = model.marketError { statusCallout(error, tint: QDesign.caution, icon: "arrow.clockwise.circle.fill") }
                        if let issues = model.snapshot?.auditIssues, !issues.isEmpty {
                            ForEach(issues, id: \.self) { statusCallout($0, tint: QDesign.caution, icon: "exclamationmark.triangle.fill") }
                        }
                        HStack {
                            Button { Task { await model.refreshMarketData(force: true) } } label: {
                                Label(model.isRefreshing ? "正在刷新…" : "立即刷新", systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isRefreshing)
                            Button { importing = true } label: { Label("导入快照…", systemImage: "square.and.arrow.down") }
                            Button { model.openDataFolder() } label: { Label("数据文件夹", systemImage: "folder") }
                        }
                        Text("导入文件必须是 schemaVersion 2 的 QQQM 快照。App 仅读取与展示数据，不含任何下单功能。")
                            .font(.caption).foregroundStyle(QDesign.secondary)
                    }

                    settingsSection("安全边界", icon: "checkmark.shield") {
                    Label("只读 · 不下单", systemImage: "lock.shield.fill")
                        .foregroundStyle(QDesign.positive)
                    Text("规则只生成计划建议；确认操作只在本地保存记录，不会创建、提交或传输 IBKR 订单。")
                            .font(.caption).foregroundStyle(QDesign.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: staticPreview ? 820 : 620)
        .background(QDesign.background)
        .foregroundStyle(QDesign.primary)
        .tint(QDesign.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.importSnapshot(from: url) }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: StatusGlyphImage.make(state: model.iconState))
                .renderingMode(.template)
                .resizable().scaledToFit()
                .foregroundStyle(QDesign.primary)
                .frame(width: 24, height: 24)
                .frame(width: 42, height: 42)
                .background(QDesign.elevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(QDesign.separator, lineWidth: 0.7))
            VStack(alignment: .leading, spacing: 2) {
                Text("QQQMBar").font(.system(size: 17, weight: .semibold))
                Text("只读定投计划助手").font(.system(size: 11)).foregroundStyle(QDesign.secondary)
            }
            Spacer()
            Label(dataState.title, systemImage: dataState.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dataState.tint)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
    }

    private var dataState: (title: String, icon: String, tint: Color) {
        if model.isRefreshing { return ("正在更新", "arrow.triangle.2.circlepath", QDesign.accent) }
        if model.marketError != nil { return ("沿用有效快照", "arrow.clockwise.circle.fill", QDesign.caution) }
        if let issues = model.snapshot?.auditIssues, !issues.isEmpty { return ("需要检查", "exclamationmark.triangle.fill", QDesign.caution) }
        if model.snapshot == nil { return ("数据不可用", "xmark.circle.fill", QDesign.negative) }
        return ("数据已校验", "checkmark.seal.fill", QDesign.positive)
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(QDesign.primary)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title, icon: icon)
            Rectangle().fill(QDesign.separator.opacity(0.75)).frame(height: 0.6)
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(QDesign.separator.opacity(0.82), lineWidth: 0.65))
    }

    private func settingsValueRow(_ title: String, _ value: String, valueTint: Color = QDesign.primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(QDesign.secondary)
            Spacer()
            Text(value).foregroundStyle(valueTint).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }

    private func statusCallout(_ text: String, tint: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private func ruleRow(_ amount: String, _ title: String, _ condition: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(amount)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 38, alignment: .leading)
            Text(title).font(.system(size: 11, weight: .medium)).frame(width: 58, alignment: .leading)
            Text(condition).font(.system(size: 10, design: .rounded)).foregroundStyle(QDesign.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#if QQQMBAR_RENDER_TEST
private struct IconQAView: View {
    private let states: [(String, Color?)] = [
        ("常态", nil),
        ("基准", QDesign.accent),
        ("多投", QDesign.positive),
        ("少投", QDesign.caution),
        ("异常", QDesign.negative)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("菜单栏状态图标").font(.system(size: 11, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    iconCell(background: Color.white.opacity(0.90), foreground: .black, badge: state.1, label: state.0)
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    iconCell(background: Color.black.opacity(0.88), foreground: .white, badge: state.1, label: state.0)
                }
            }
        }
        .padding(16)
        .foregroundStyle(QDesign.primary)
        .background(QDesign.background)
    }

    private func iconCell(background: Color, foreground: Color, badge: Color?, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Image(nsImage: StatusGlyphImage.make(state: .pending))
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(foreground)
                    .frame(width: 18, height: 18)
                if let badge { Circle().fill(badge).frame(width: 4, height: 4).offset(x: 8, y: -7) }
            }
            .frame(width: 30, height: 26)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(label).font(.system(size: 7.5)).foregroundStyle(QDesign.secondary)
        }
    }
}

@main
struct QQQMBarRenderTest {
    @MainActor
    static func main() async throws {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var snapshot: QQQMSnapshot
        if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(QQQMSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[flag + 1])))
            if arguments.contains("--refresh") { snapshot = try await LiveMarketDataService().refreshedSnapshot(from: snapshot) }
        } else {
            snapshot = arguments.contains("--live") ? try await LiveMarketDataService().refreshedSnapshot(from: .fixture) : .fixture
        }
        let unavailable = arguments.contains("--unavailable")
        let confirmed = arguments.contains("--confirmed")
        let model = AppModel(
            previewSnapshot: unavailable ? nil : snapshot,
            previewConfirmation: confirmed ? PlanConfirmation(recommendationID: snapshot.recommendation.id, confirmedAt: Date()) : nil,
            previewMarketError: arguments.contains("--market-error") ? "市场数据刷新失败：网络暂不可用" : nil,
            previewLoadError: unavailable ? "快照结构校验失败，上一份文件未被覆盖。" : nil,
            previewIsRefreshing: arguments.contains("--refreshing"),
            forcePreviewMode: true
        )
        let iconsOnly = arguments.contains("--icons")
        let settingsOnly = arguments.contains("--settings")
        let content: AnyView
        if iconsOnly {
            content = AnyView(IconQAView())
        } else if settingsOnly {
            content = AnyView(SettingsView(staticPreview: true).environmentObject(model))
        } else {
            content = AnyView(MenuPopoverView(initialRuleDisclosure: arguments.contains("--expanded")).environmentObject(model))
        }
        let scheme: ColorScheme = arguments.contains("--light") ? .light : .dark
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
        let previewHeight: CGFloat = arguments.contains("--expanded") ? 950 : DashboardLayout.height
        if iconsOnly {
            renderer.proposedSize = ProposedViewSize(width: 330, height: 150)
        } else if settingsOnly {
            renderer.proposedSize = ProposedViewSize(width: 500, height: 820)
        } else {
            renderer.proposedSize = ProposedViewSize(width: DashboardLayout.width, height: previewHeight)
        }
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
        let output = arguments.first(where: { $0.hasSuffix(".png") }) ?? "/tmp/QQQMBar-render.png"
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        print(output)
    }
}
#elseif QQQMBAR_SELF_TEST
@main
struct QQQMBarSelfTest {
    static func main() {
        let snapshot = QQQMSnapshot.fixture
        precondition(snapshot.auditIssues.isEmpty, "Fixture audit failed: \(snapshot.auditIssues.joined(separator: ", "))")
        precondition(abs(snapshot.verifiedMarketValue - 295) < 0.001)
        precondition(abs(snapshot.verifiedUnrealizedPnL - (-5)) < 0.001)
        precondition(abs(snapshot.verifiedNAV - 10_000) < 0.001)
        precondition(snapshot.quote.dayLow == 294.45 && snapshot.quote.dayHigh == 298.16)
        precondition(abs(snapshot.quote.dayChangePct - ((295.00 / 296.92 - 1) * 100)) < 0.0001)
        precondition(snapshot.signals.count == 4 && snapshot.signals.allSatisfy { $0.value != "未接入" })
        let ema = exponentialMovingAverage(snapshot.priceHistory, period: 20)
        precondition(ema.count == snapshot.priceHistory.count && ema.allSatisfy { $0.close.isFinite && $0.close > 0 })
        precondition(dcaAllocationBand(momentum: -11, vix: 20, sentimentScore: 50) == .strongIncrease)
        precondition(dcaAllocationBand(momentum: -6, vix: 20, sentimentScore: 50) == .increase)
        precondition(dcaAllocationBand(momentum: 1, vix: 20, sentimentScore: 50) == .normal)
        precondition(dcaAllocationBand(momentum: 10, vix: 17, sentimentScore: 70) == .decrease)
        precondition(dcaAllocationBand(momentum: 16, vix: 17, sentimentScore: 80) == .strongDecrease)
        let neutralAudit = DCAConditionAudit(momentum: 2.9, vix: 14.5, sentiment: 54)
        precondition(neutralAudit.moreCount == 0 && neutralAudit.lessCount == 1 && neutralAudit.band == .normal)
        precondition(abs(neutralAudit.moreGaps[0] - 7.9) < 0.001)
        precondition(abs(neutralAudit.moreGaps[1] - 14) < 0.001)
        precondition(abs(neutralAudit.moreGaps[2] - 10.5) < 0.001)
        precondition(abs(neutralAudit.lessGaps[0] - 5.1) < 0.001)
        precondition(abs(neutralAudit.lessGaps[1] - 11) < 0.001)
        precondition(neutralAudit.lessGaps[2] == 0)
        let moreAudit = DCAConditionAudit(momentum: -6, vix: 20, sentiment: 50)
        precondition(moreAudit.moreCount == 1 && moreAudit.band == .increase)
        let lessAudit = DCAConditionAudit(momentum: 10, vix: 17, sentiment: 70)
        precondition(lessAudit.lessCount == 3 && lessAudit.band == .decrease)
        let cnnJSON = #"{"fear_and_greed":{"score":54.4285714285714,"rating":"neutral","timestamp":"2026-08-28T23:59:58+00:00"}}"#.data(using: .utf8)!
        let cnn = try! LiveMarketDataService.parseCNNFearGreed(cnnJSON)
        precondition(abs(cnn.score - 54.4285714285714) < 0.0001 && cnn.localizedRating == "中性")
        let cnnMarketJSON = #"{"fear_and_greed":{"score":44.5714285714286,"rating":"fear","timestamp":"2026-09-01T23:30:10+00:00"},"market_volatility_vix":{"data":[{"x":1788293701000,"y":16.34,"rating":"extreme fear"}]}}"#.data(using: .utf8)!
        let cnnMarket = try! LiveMarketDataService.parseCNNMarketObservation(cnnMarketJSON)
        precondition(cnnMarket.fearGreed.localizedRating == "恐惧" && cnnMarket.vix.value == 16.34)
        precondition(cnnMarket.vix.date.formatted(.iso8601) == "2026-09-01T20:15:01Z")
        let beforeFirstRefresh = ISO8601DateFormatter().date(from: "2026-08-31T20:04:00Z")!
        let afterFirstRefresh = ISO8601DateFormatter().date(from: "2026-08-31T20:06:00Z")!
        precondition(MarketRefreshSchedule.nextRefresh(after: beforeFirstRefresh).formatted(.iso8601) == "2026-08-31T20:05:00Z")
        precondition(MarketRefreshSchedule.nextRefresh(after: afterFirstRefresh).formatted(.iso8601) == "2026-09-01T20:05:00Z")
        precondition(MarketRefreshSchedule.isDue(lastRefresh: beforeFirstRefresh, now: afterFirstRefresh))
        let tuesdayEvening = ISO8601DateFormatter().date(from: "2026-09-01T23:30:00Z")!
        let staleMonday = ISO8601DateFormatter().date(from: "2026-08-31T00:00:00Z")!
        let freshTuesday = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!
        precondition(MarketRefreshSchedule.expectedSessionDate(at: tuesdayEvening) == freshTuesday)
        precondition(!MarketRefreshSchedule.isFresh(marketDate: staleMonday, now: tuesdayEvening))
        precondition(MarketRefreshSchedule.isFresh(marketDate: freshTuesday, now: tuesdayEvening))
        precondition(MarketRefreshSchedule.retryDate(after: tuesdayEvening)?.formatted(.iso8601) == "2026-09-02T00:00:00Z")
        let firstAttemptFailure = ISO8601DateFormatter().date(from: "2026-09-01T20:06:00Z")!
        precondition(MarketRefreshSchedule.retryDate(after: firstAttemptFailure)?.formatted(.iso8601) == "2026-09-01T20:11:00Z")
        let laborDay = ISO8601DateFormatter().date(from: "2026-09-07T21:00:00Z")!
        precondition(MarketRefreshSchedule.expectedSessionDate(at: laborDay).formatted(.iso8601) == "2026-09-04T00:00:00Z")
        precondition(MarketRefreshSchedule.nextRefresh(after: ISO8601DateFormatter().date(from: "2026-09-04T21:00:00Z")!).formatted(.iso8601) == "2026-09-08T20:05:00Z")
        let infoJSON = #"{"data":{"secondaryData":{"lastSalePrice":"$291.40","lastTradeTimestamp":"Closed at Sep 1, 2026 4:00 PM ET"}}}"#.data(using: .utf8)!
        let summaryJSON = #"{"data":{"summaryData":{"PreviousClose":{"value":"$295.18"},"TodayHighLow":{"value":"$293.30/$290.15"}}}}"#.data(using: .utf8)!
        let officialClose = try! LiveMarketDataService.parseNasdaqOfficialClose(infoData: infoJSON, summaryData: summaryJSON)
        precondition(officialClose.date == freshTuesday && officialClose.close == 291.40 && officialClose.previousClose == 295.18)
        precondition(officialClose.low == 290.15 && officialClose.high == 293.30)
        precondition(snapshot.recommendation.nextExecution.formatted(.iso8601) == "2026-09-01T13:30:00Z")
        let now = Date()
        let calendar = Calendar.current
        precondition(dcaReminderTitle(nextExecution: calendar.date(byAdding: .day, value: 2, to: now), confirmed: false, hasError: false, now: now) == "2天")
        precondition(dcaReminderTitle(nextExecution: calendar.date(byAdding: .day, value: 1, to: now), confirmed: false, hasError: false, now: now) == "明日")
        precondition(dcaReminderTitle(nextExecution: now, confirmed: false, hasError: false, now: now) == "今日")
        precondition(dcaReminderTitle(nextExecution: now, confirmed: true, hasError: false, now: now) == "✓")
        let sameSessionMorning = ISO8601DateFormatter().date(from: "2026-08-18T14:59:39Z")!
        let sameSessionAfternoon = ISO8601DateFormatter().date(from: "2026-08-18T19:52:17Z")!
        let nextShanghaiDay = ISO8601DateFormatter().date(from: "2026-08-25T19:52:47Z")!
        precondition(marketTradingDayDate(for: sameSessionMorning) == marketTradingDayDate(for: sameSessionAfternoon))
        precondition(marketTradingDayDate(for: sameSessionMorning).formatted(.iso8601) == "2026-08-18T00:00:00Z")
        precondition(marketTradingDayDate(for: nextShanghaiDay).formatted(.iso8601) == "2026-08-25T00:00:00Z")
        let groupedTrade = aggregateTradeValues([
            BuyMarker(id: "a", date: sameSessionMorning, price: 295.0195, quantity: 1, amount: 295.0195),
            BuyMarker(id: "b", date: sameSessionAfternoon, price: 295.686093, quantity: 1.3527, amount: 399.9745780011)
        ])!
        precondition(abs(groupedTrade.amount - 694.9940780011) < 0.000001)
        precondition(abs(groupedTrade.price - 295.4027619336) < 0.0001)
        let individualSnapshot = QQQMSnapshot(
            schemaVersion: snapshot.schemaVersion,
            symbol: snapshot.symbol,
            source: snapshot.source,
            quote: snapshot.quote,
            portfolio: snapshot.portfolio,
            priceHistory: snapshot.priceHistory,
            buyMarkers: [
                BuyMarker(id: "a", date: sameSessionMorning, price: 295.0195, quantity: 1, amount: 295.0195),
                BuyMarker(id: "b", date: sameSessionAfternoon, price: 295.686093, quantity: 1.3527, amount: 399.9745780011)
            ],
            recommendation: snapshot.recommendation,
            signals: snapshot.signals
        )
        let individualEvents = individualTradeEvents(
            individualSnapshot,
            within: marketTradingDayDate(for: sameSessionMorning)...marketTradingDayDate(for: sameSessionAfternoon)
        )
        precondition(individualEvents.count == 2)
        precondition(individualEvents.map(\.ordinal) == [1, 2])
        precondition(abs(individualEvents[0].price - 295.0195) < 0.000001)
        precondition(abs(individualEvents[1].price - 295.686093) < 0.000001)
        print("QQQMBAR SELF TEST: PASS")
    }
}
#elseif QQQMBAR_LIVE_TEST
@main
struct QQQMBarLiveDataSelfTest {
    static func main() async throws {
        let base = QQQMSnapshot.fixture
        let accountSeed = QQQMSnapshot(
            schemaVersion: base.schemaVersion,
            symbol: base.symbol,
            source: DataSourceInfo(name: base.source.name, mode: base.source.mode, asOf: base.source.asOf, notes: base.source.notes, accountSource: "IBKR 插件（只读）", accountAsOf: Date()),
            quote: base.quote,
            portfolio: base.portfolio,
            priceHistory: base.priceHistory,
            buyMarkers: base.buyMarkers,
            recommendation: base.recommendation,
            signals: base.signals
        )
        let snapshot = try await LiveMarketDataService().refreshedSnapshot(from: accountSeed)
        precondition(snapshot.source.mode == .live)
        precondition(snapshot.source.accountSource == "IBKR 插件（只读）")
        precondition(snapshot.priceHistory.count == 30)
        precondition(snapshot.signals.count == 4 && snapshot.signals.allSatisfy { $0.value != "未接入" })
        precondition(snapshot.signals[2].id == "live-cnn-fear-greed")
        precondition(snapshot.signals[2].value != "—" && snapshot.signals[2].source.hasPrefix("CNN"))
        precondition(snapshot.auditIssues.isEmpty, "Live audit failed: \(snapshot.auditIssues.joined(separator: ", "))")
        precondition(snapshot.recommendation.id.hasPrefix("live-plan-"))
        precondition(snapshot.recommendation.baseAmount == 400)
        precondition([200.0, 300.0, 400.0, 500.0, 600.0].contains(snapshot.recommendation.recommendedAmount))
        precondition(!snapshot.recommendation.explanation.contains("fixture"))
        print("live diagnostics: price=\(snapshot.quote.lastPrice) points=\(snapshot.priceHistory.count) signals=\(snapshot.signals.map { "\($0.title):\($0.value)" }.joined(separator: " | "))")
        print("QQQMBAR LIVE DATA TEST: PASS")
    }
}
#elseif QQQMBAR_INTERACTION_TEST
@main
struct QQQMBarInteractionSelfTest {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusBarController()
        app.delegate = controller
        app.finishLaunching()
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(controller.runInteractionSelfTest(), "Popover interaction contract failed")
        print("QQQMBAR INTERACTION TEST: PASS")
    }
}
#else
@main
struct QQQMBarApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBarController
    var body: some Scene {
        Settings { SettingsView().environmentObject(statusBarController.model) }
    }
}
#endif
