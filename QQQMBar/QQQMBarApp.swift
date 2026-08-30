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
        case .normal: "维持基准"
        case .increase: "建议加码"
        case .decrease: "建议减码"
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

    init(name: String, mode: SnapshotMode, asOf: Date, notes: String?, accountSource: String? = nil, accountAsOf: Date? = nil) {
        self.name = name
        self.mode = mode
        self.asOf = asOf
        self.notes = notes
        self.accountSource = accountSource
        self.accountAsOf = accountAsOf
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
            portfolio: PortfolioSnapshot(shares: 4.7202, marketValue: 1392.459, averageCost: 295.2521927, unrealizedPnL: -1.1904, nav: 41028.94, availableFunds: 1035.86),
            priceHistory: history,
            buyMarkers: [
                BuyMarker(id: "fixture-2026-08-11-1", date: date("2026-08-11"), price: 297.26, quantity: 1, amount: 297.26),
                BuyMarker(id: "fixture-2026-08-18-1", date: date("2026-08-18"), price: 295.0195, quantity: 1, amount: 295.02),
                BuyMarker(id: "fixture-2026-08-18-2", date: date("2026-08-18"), price: 295.686093, quantity: 1.3527, amount: 399.97),
                BuyMarker(id: "fixture-2026-08-25-1", date: date("2026-08-25"), price: 292.500646, quantity: 1.3675, amount: 399.99)
            ],
            recommendation: DCARecommendation(id: "fixture-plan-2026-09-01-v1", baseAmount: 400, recommendedAmount: 400, kind: .normal, nextExecution: ISO8601DateFormatter().date(from: "2026-09-01T13:30:00Z")!, generatedAt: updated, explanation: "开发 fixture：维持每周基准计划。"),
            signals: [
                MarketSignal(id: "fixture-momentum", title: "30D 趋势", value: "+4.9%", normalized: 0.74, source: "QQQM 日线", asOf: updated, mode: .fixture),
                MarketSignal(id: "fixture-vix", title: "VIX", value: "14.5", normalized: 0.36, source: "FRED · 8/27", asOf: updated, mode: .fixture),
                MarketSignal(id: "fixture-sentiment", title: "市场情绪", value: "偏强 64", normalized: 0.64, source: "RSI + VIX", asOf: updated, mode: .fixture),
                MarketSignal(id: "fixture-valuation", title: "QQQM P/E", value: "36.52×", normalized: 0.73, source: "Invesco · 3/31", asOf: updated, mode: .fixture)
            ]
        )
    }()
}

enum LiveMarketDataError: LocalizedError {
    case invalidResponse(String)
    case insufficientHistory(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let source): "\(source) 返回的数据无法解析"
        case .insufficientHistory(let count): "Nasdaq 日线数量不足：\(count)"
        }
    }
}

struct VIXObservation: Hashable {
    let date: Date
    let value: Double
}

struct LiveMarketDataService {
    // Official fund fact sheet, Q1 2026. This is intentionally a dated
    // fundamental snapshot rather than a made-up real-time valuation score.
    static let officialPERatio = 36.52
    static let officialPEAsOf = ISO8601DateFormatter().date(from: "2026-03-31T20:00:00Z")!

    func refreshedSnapshot(from current: QQQMSnapshot) async throws -> QQQMSnapshot {
        async let nasdaqTask = fetchNasdaqHistory()
        async let vixTask = fetchLatestVIX()
        let allHistory = try await nasdaqTask
        let vix = try? await vixTask
        guard allHistory.count >= 30 else { throw LiveMarketDataError.insufficientHistory(allHistory.count) }

        let chartHistory = Array(allHistory.suffix(30))
        guard let latest = allHistory.last, allHistory.count >= 2 else {
            throw LiveMarketDataError.insufficientHistory(allHistory.count)
        }
        let previous = allHistory[allHistory.count - 2]
        let yearStart = allHistory.first!
        let dayRow = try await fetchLatestNasdaqBar()
        let dayChange = (latest.close / previous.close - 1) * 100
        let ytd = (latest.close / yearStart.close - 1) * 100
        let volatility = annualizedVolatility(Array(allHistory.suffix(31)).map(\.close))
        let momentum = (latest.close / chartHistory.first!.close - 1) * 100
        let rsi = relativeStrengthIndex(Array(allHistory.suffix(15)).map(\.close))
        let riskAppetite = vix.map { clamp((32 - $0.value) / 22 * 100) } ?? 50
        let trendScore = clamp(50 + momentum * 4.2)
        let sentimentScore = clamp(rsi * 0.55 + riskAppetite * 0.30 + trendScore * 0.15)
        let sentimentLabel: String
        switch sentimentScore {
        case ..<35: sentimentLabel = "偏弱"
        case 65...: sentimentLabel = "偏强"
        default: sentimentLabel = "中性"
        }

        let recommendation = liveRecommendation(
            from: current.recommendation,
            marketDate: latest.date,
            momentum: momentum,
            vix: vix?.value,
            sentimentScore: sentimentScore
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
        let vixSource = vix.map { "FRED · \($0.date.formatted(.dateTime.month(.defaultDigits).day()))" } ?? "FRED 暂不可用"
        let accountNote = current.source.accountSource == nil ? "账户数据为本地快照。" : "账户数据由 IBKR 插件同步。"
        let sourceNotes = "QQQM 日线：Nasdaq；VIX：FRED；P/E：Invesco Q1 2026。\(accountNote)"

        return QQQMSnapshot(
            schemaVersion: QQQMSnapshot.currentSchemaVersion,
            symbol: current.symbol,
            source: DataSourceInfo(
                name: current.source.accountSource == nil ? "Nasdaq + FRED + Invesco" : "IBKR + Nasdaq + FRED + Invesco",
                mode: .live,
                asOf: latest.date,
                notes: sourceNotes,
                accountSource: current.source.accountSource,
                accountAsOf: current.source.accountAsOf
            ),
            quote: QuoteSnapshot(
                lastPrice: latest.close,
                dayChangePct: dayChange,
                dayLow: dayRow.low,
                dayHigh: dayRow.high,
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
                MarketSignal(id: "live-sentiment", title: "市场情绪", value: "\(sentimentLabel) \(Int(sentimentScore.rounded()))", normalized: sentimentScore / 100, source: "RSI + VIX", asOf: latest.date, mode: .live),
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

    func fetchLatestVIX() async throws -> VIXObservation {
        let url = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=VIXCLS")!
        return try Self.parseLatestVIX(try await request(url))
    }

    private func request(_ url: URL, referer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        request.setValue("QQQMBar/0.5 macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/csv;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
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

    private func liveRecommendation(from current: DCARecommendation, marketDate: Date, momentum: Double, vix: Double?, sentimentScore: Double) -> DCARecommendation {
        let kind: RecommendationKind
        let multiplier: Double
        if momentum <= -5 || sentimentScore < 35 {
            kind = .increase
            multiplier = 1.25
        } else if momentum >= 8 && sentimentScore >= 70 {
            kind = .decrease
            multiplier = 0.75
        } else {
            kind = .normal
            multiplier = 1
        }
        let amount = (current.baseAmount * multiplier / 25).rounded() * 25
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: current.nextExecution)
        let executionDay = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let vixText = vix.map { String(format: "%.1f", $0) } ?? "暂不可用"
        return DCARecommendation(
            id: "live-plan-\(executionDay)-\(kind.rawValue)-\(Int(amount))",
            baseAmount: current.baseAmount,
            recommendedAmount: amount,
            kind: kind,
            nextExecution: current.nextExecution,
            generatedAt: marketDate,
            explanation: String(format: "真实行情规则：QQQM 30 日涨跌 %+.2f%%，VIX %@，综合情绪 %.0f/100；据此采用 %.2f× 基准金额。", momentum, vixText, sentimentScore, multiplier)
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

    init(previewSnapshot: QQQMSnapshot? = nil) {
        if let previewSnapshot {
            previewMode = true
            snapshot = previewSnapshot
            confirmation = nil
            loadError = nil
            marketError = nil
            return
        }
        previewMode = false
        do {
            try store.prepareInitialSnapshot()
            reload()
            Task { @MainActor [weak self] in await self?.refreshMarketData() }
        }
        catch { loadError = error.localizedDescription }
    }

    var iconState: GlyphState {
        guard let snapshot else { return .error }
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
    func refreshMarketData() async {
        guard !previewMode, !isRefreshing, let snapshot else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let refreshed = try await LiveMarketDataService().refreshedSnapshot(from: snapshot)
            try store.save(refreshed)
            self.snapshot = refreshed
            marketError = nil
            loadError = nil
        } catch {
            marketError = "市场数据刷新失败：\(error.localizedDescription)"
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

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var outsideMouseMonitor: Any?
    private var localMouseMonitor: Any?
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
        popover.contentSize = NSSize(width: 344, height: 600)
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView().environmentObject(model))
        updateStatusItem()
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
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
        let badgeColor: NSColor? = switch reminder {
        case "✓": .systemGreen
        case "今日", "明日": .systemOrange
        case "2天", "3天": .systemPurple
        case "逾期", "!": .systemRed
        default: nil
        }
        statusBadge.layer?.backgroundColor = badgeColor?.cgColor
        statusBadge.isHidden = badgeColor == nil
        let label = reminder.isEmpty ? statusLabel(for: model.iconState) : "\(statusLabel(for: model.iconState))，\(reminder)"
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func statusLabel(for state: GlyphState) -> String {
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

private enum DashboardPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.72)
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let cyan = Color(red: 0.27, green: 0.76, blue: 0.78)
    static let blue = cyan
    static let green = Color(red: 0.43, green: 0.75, blue: 0.49)
    static let purple = Color(red: 0.62, green: 0.49, blue: 0.82)
    static let orange = Color(red: 0.86, green: 0.64, blue: 0.24)
    static let coral = Color(red: 0.88, green: 0.41, blue: 0.37)
    static let steel = Color(red: 0.49, green: 0.65, blue: 0.69)
    static let gold = orange
    static let ink = Color(red: 0.035, green: 0.075, blue: 0.086)
}

private enum DashboardLayout {
    static let width: CGFloat = 344
    static let height: CGFloat = 600
    static let contentWidth: CGFloat = 330
    static let gutter: CGFloat = 4
    static let halfCardWidth: CGFloat = 163
    static let thirdCardWidth: CGFloat = 107.33
}

private struct DashboardCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color
    @ViewBuilder let content: Content
    init(tint: Color = DashboardPalette.steel, @ViewBuilder content: () -> Content) { self.tint = tint; self.content = content() }
    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                ZStack {
                    if colorScheme == .light {
                        shape.fill(LinearGradient(colors: [Color(red: 0.985, green: 0.992, blue: 0.990), Color(red: 0.945, green: 0.967, blue: 0.965)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        shape.fill(LinearGradient(colors: [Color(red: 0.067, green: 0.133, blue: 0.157).opacity(0.94), Color(red: 0.027, green: 0.067, blue: 0.082).opacity(0.96)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    shape.fill(RadialGradient(colors: [tint.opacity(colorScheme == .light ? 0.11 : 0.17), .clear], center: UnitPoint(x: 0.52, y: 0.15), startRadius: 0, endRadius: 165))
                    shape.fill(LinearGradient(colors: [Color.white.opacity(colorScheme == .light ? 0.34 : 0.055), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.42, y: 0.48)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(colorScheme == .light ? DashboardPalette.steel.opacity(0.22) : DashboardPalette.steel.opacity(0.18), lineWidth: 0.55))
            .shadow(color: Color.black.opacity(colorScheme == .light ? 0.055 : 0.26), radius: colorScheme == .light ? 7 : 14, y: colorScheme == .light ? 3 : 7)
            .clipped()
    }
}

private struct RingBadge: View {
    let confirmed: Bool
    let isRefreshing: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .overlay(Circle().stroke(DashboardPalette.border, lineWidth: 0.7))
            Text("Q")
                .font(.system(size: 25, weight: .medium, design: .default))
                .foregroundStyle(DashboardPalette.text)
                .offset(y: -0.5)
            Circle()
                .fill(isRefreshing ? DashboardPalette.blue : (confirmed ? DashboardPalette.green : DashboardPalette.purple))
                .frame(width: 6, height: 6)
                .offset(x: 13.2, y: 13.2)
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel(confirmed ? "本周计划已确认" : "本周计划待确认")
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let range = max(maximum - minimum, 0.001)
            Path { path in
                for index in values.indices {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = proxy.size.height * (1 - CGFloat((values[index] - minimum) / range))
                    index == values.startIndex ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct AllocationRing: View {
    let qqqm: Double
    let cash: Double

    private var segments: [(Double, Color)] {
        let qqqm = min(max(qqqm, 0), 1)
        let cash = min(max(cash, 0), 1 - qqqm)
        return [(qqqm, DashboardPalette.blue), (cash, DashboardPalette.green), (max(0, 1 - qqqm - cash), DashboardPalette.purple)]
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 4
            var start = -90.0
            for (value, color) in segments where value > 0 {
                var path = Path()
                let end = start + value * 360
                path.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                start = end
            }
        }
        .accessibilityLabel("账户资产构成")
    }
}

private struct FundsGauge: View {
    let value: Double
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 1)
            let radius = min(size.width / 2 - 3, size.height - 4)
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(DashboardPalette.border), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            var progress = Path()
            progress.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * min(max(value, 0), 1)), clockwise: false)
            context.stroke(progress, with: .color(DashboardPalette.green), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}

private enum TradeDirection: String { case buy, sell }

private struct ChartTradeEvent: Identifiable {
    let id: String
    let date: Date
    let price: Double
    let count: Int
    let direction: TradeDirection
}

private func exponentialMovingAverage(_ points: [PricePoint], period: Int) -> [PricePoint] {
    guard period > 0, let first = points.first else { return [] }
    let alpha = 2.0 / Double(period + 1)
    var value = first.close
    return points.enumerated().map { index, point in
        if index > 0 { value = point.close * alpha + value * (1 - alpha) }
        return PricePoint(date: point.date, close: value)
    }
}

private struct PositionCostVisualizer: View {
    let averageCost: Double
    let currentPrice: Double

    private var lower: Double { min(averageCost, currentPrice) * 0.997 }
    private var upper: Double { max(averageCost, currentPrice) * 1.003 }
    private func position(_ value: Double) -> Double { upper > lower ? min(max((value - lower) / (upper - lower), 0), 1) : 0.5 }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let costX = proxy.size.width * position(averageCost)
                let priceX = proxy.size.width * position(currentPrice)
                ZStack(alignment: .leading) {
                    Capsule().fill(DashboardPalette.border).frame(height: 4)
                    Capsule()
                        .fill((currentPrice >= averageCost ? DashboardPalette.green : DashboardPalette.coral).opacity(0.62))
                        .frame(width: max(abs(priceX - costX), 2), height: 4)
                        .offset(x: min(costX, priceX))
                    Rectangle().fill(DashboardPalette.muted).frame(width: 1, height: 11).offset(x: costX)
                    Circle().fill(currentPrice >= averageCost ? DashboardPalette.green : DashboardPalette.coral)
                        .frame(width: 7, height: 7).overlay(Circle().stroke(.background, lineWidth: 1)).offset(x: priceX - 3.5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            HStack {
                Text("成本 \(averageCost, format: .currency(code: "USD").precision(.fractionLength(2)))")
                Spacer()
                Text("现价 \(currentPrice, format: .currency(code: "USD").precision(.fractionLength(2)))")
            }
            .font(.system(size: 5.8, weight: .medium, design: .rounded))
            .foregroundStyle(DashboardPalette.muted)
        }
        .accessibilityLabel("平均成本与当前价格对比")
    }
}

struct PriceChartView: View {
    let snapshot: QQQMSnapshot
    @State private var selectedDate: Date?

    private var ema20: [PricePoint] { exponentialMovingAverage(snapshot.priceHistory, period: 20) }

    private var chartDomain: ClosedRange<Double> {
        let values = snapshot.priceHistory.map(\.close) + ema20.map(\.close) + tradeEvents.map(\.price)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.10, high * 0.004)
        return (low - padding)...(high + padding)
    }
    private var dateDomain: ClosedRange<Date> {
        guard let first = snapshot.priceHistory.first?.date, let last = snapshot.priceHistory.last?.date else { return Date()...Date() }
        return first...last
    }
    private var selectedPoint: PricePoint? {
        guard let selectedDate else { return nil }
        return snapshot.priceHistory.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var tradeEvents: [ChartTradeEvent] {
        let markers = snapshot.buyMarkers.filter { dateDomain.contains($0.date) }
        let grouped = Dictionary(grouping: markers) { marker in
            "\(tradingDay(for: marker.date).timeIntervalSince1970)-\(marker.quantity < 0 ? "sell" : "buy")"
        }
        return grouped.compactMap { key, values in
            guard let first = values.first else { return nil }
            let direction: TradeDirection = first.quantity < 0 ? .sell : .buy
            let totalQuantity = values.reduce(0) { $0 + abs($1.quantity) }
            let price = totalQuantity > 0 ? values.reduce(0) { $0 + $1.price * abs($1.quantity) } / totalQuantity : first.price
            return ChartTradeEvent(id: key, date: tradingDay(for: first.date), price: price, count: values.count, direction: direction)
        }.sorted { $0.date < $1.date }
    }
    private func tradingDay(for date: Date) -> Date {
        var marketCalendar = Calendar(identifier: .gregorian)
        marketCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let components = marketCalendar.dateComponents([.year, .month, .day], from: date)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return utcCalendar.date(from: components) ?? date
    }
    private var axisDates: [Date] {
        let history = snapshot.priceHistory
        guard !history.isEmpty else { return [] }
        return [0, history.count / 2, history.count - 1].map { history[$0].date }
    }
    var body: some View {
        Chart {
            ForEach(snapshot.priceHistory) { point in
                AreaMark(x: .value("日期", point.date), yStart: .value("基线", chartDomain.lowerBound), yEnd: .value("价格", point.close))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [DashboardPalette.blue.opacity(0.20), DashboardPalette.blue.opacity(0.015)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("日期", point.date), y: .value("价格", point.close), series: .value("系列", "价格"))
                    .foregroundStyle(DashboardPalette.blue)
                    .lineStyle(.init(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(ema20) { point in
                LineMark(x: .value("日期", point.date), y: .value("EMA20", point.close), series: .value("系列", "EMA20"))
                    .foregroundStyle(DashboardPalette.orange.opacity(0.92))
                    .lineStyle(.init(lineWidth: 1.05, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let last = snapshot.priceHistory.last {
                PointMark(x: .value("最新日期", last.date), y: .value("最新价", last.close))
                    .symbol {
                        Circle().fill(.white).frame(width: 5, height: 5).overlay(Circle().stroke(DashboardPalette.blue, lineWidth: 1.5))
                    }
            }
            ForEach(tradeEvents) { event in
                PointMark(x: .value("成交日期", event.date), y: .value("成交价格", event.price))
                    .symbol {
                        Text(event.direction == .buy ? "B" : "S")
                            .font(.system(size: 5.8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 12, height: 12)
                            .background(event.direction == .buy ? DashboardPalette.green : DashboardPalette.coral, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.78), lineWidth: 0.7))
                            .shadow(color: Color.black.opacity(0.18), radius: 1, y: 0.5)
                            .help("\(event.direction == .buy ? "买入" : "卖出") · \(event.count) 笔 · $\(event.price, specifier: "%.2f")")
                    }
            }
            if let selectedPoint {
                RuleMark(x: .value("选中日期", selectedPoint.date))
                    .foregroundStyle(DashboardPalette.muted.opacity(0.55))
                    .lineStyle(.init(lineWidth: 0.6, dash: [2, 2]))
                PointMark(x: .value("选中日期", selectedPoint.date), y: .value("选中价格", selectedPoint.close))
                    .foregroundStyle(DashboardPalette.text)
                    .symbolSize(30)
                    .annotation(position: .top, spacing: 4) {
                        HStack(spacing: 3) {
                            Text(selectedPoint.date, format: .dateTime.month(.defaultDigits).day())
                            Text(String(format: "$%.2f", selectedPoint.close)).fontWeight(.semibold)
                        }
                        .font(.system(size: 6.5, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .chartXScale(domain: dateDomain).chartYScale(domain: chartDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).font(.system(size: 6)).foregroundStyle(DashboardPalette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.35, dash: [2, 3])).foregroundStyle(DashboardPalette.border.opacity(0.55))
                AxisValueLabel { if let price = value.as(Double.self) { Text(String(format: "%.0f", price)) } }.font(.system(size: 6)).foregroundStyle(DashboardPalette.muted)
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("QQQM 最近 30 个交易日收盘价、EMA20 趋势与成交点")
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color
    let spark: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 7, weight: .medium)).foregroundStyle(DashboardPalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) { Text(value).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(DashboardPalette.text); Image(systemName: title == "趋势" ? "arrow.up.right" : "waveform.path.ecg").font(.system(size: 8, weight: .bold)).foregroundStyle(tint) }
            Text(subtitle).font(.system(size: 7)).foregroundStyle(DashboardPalette.muted).lineLimit(1).minimumScaleFactor(0.75)
            Sparkline(values: spark, color: tint).frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }
}

struct MenuPopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group { if let snapshot = model.snapshot { content(snapshot) } else { unavailable } }
            .padding(7).frame(width: DashboardLayout.width, height: DashboardLayout.height)
            .background(.ultraThinMaterial)
            .background {
                if colorScheme == .light {
                    LinearGradient(
                        colors: [Color(red: 0.945, green: 0.969, blue: 0.965), Color(red: 0.885, green: 0.930, blue: 0.925)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    LinearGradient(colors: [Color(red: 0.025, green: 0.057, blue: 0.066), Color(red: 0.045, green: 0.095, blue: 0.108)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .onAppear {
                model.reload()
                Task { await model.refreshMarketData() }
            }
    }

    private func content(_ snapshot: QQQMSnapshot) -> some View {
        VStack(spacing: 4) {
            header(snapshot)
            chartPanel(snapshot)
            signalPanel(snapshot)
            overviewPanels(snapshot)
            bottomPanels(snapshot)
            confirmationButton(snapshot)
        }
        .foregroundStyle(DashboardPalette.text)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func header(_ snapshot: QQQMSnapshot) -> some View {
        HStack(spacing: 4) {
            RingBadge(confirmed: model.planConfirmed, isRefreshing: model.isRefreshing)
            VStack(alignment: .leading, spacing: 1) {
                Text("本周计划金额").font(.system(size: 7)).foregroundStyle(DashboardPalette.muted)
                Text(usd(snapshot.recommendation.recommendedAmount)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                HStack(spacing: 3) { Text(snapshot.recommendation.kind.label).foregroundStyle(DashboardPalette.green); Text("\(snapshot.recommendation.multiplier, specifier: "%.2f")×").foregroundStyle(DashboardPalette.muted) }.font(.system(size: 7, weight: .medium))
            }
            .frame(width: 72, alignment: .leading)
            Divider().overlay(DashboardPalette.border).frame(height: 36)
            VStack(spacing: 1) {
                Text("计划执行").font(.system(size: 7)).foregroundStyle(DashboardPalette.muted)
                Text(compactDays(snapshot.recommendation.nextExecution)).font(.system(size: 10, weight: .medium))
                Text(snapshot.recommendation.nextExecution, format: .dateTime.month(.defaultDigits).day()).font(.system(size: 7)).foregroundStyle(DashboardPalette.muted)
            }.frame(width: 46)
            Divider().overlay(DashboardPalette.border).frame(height: 36)
            Image(systemName: model.planConfirmed ? "checkmark" : "clock").font(.system(size: 14, weight: .bold)).foregroundStyle(model.planConfirmed ? DashboardPalette.green : DashboardPalette.purple).frame(width: 27, height: 27).background((model.planConfirmed ? DashboardPalette.green : DashboardPalette.purple).opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(model.planConfirmed ? "计划已确认" : "等待确认").font(.system(size: 8, weight: .medium)).lineLimit(1)
                Text("只确认 · 不下单").font(.system(size: 6)).foregroundStyle(DashboardPalette.muted).lineLimit(1)
            }.frame(width: 58, alignment: .leading)
#if QQQMBAR_RENDER_TEST
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).frame(width: 12, height: 24)
#else
            Menu { Button("刷新市场数据") { Task { await model.refreshMarketData() } }; if model.planConfirmed { Button("重新打开本周计划") { model.reopenPlan() } }; Button("打开数据文件夹") { model.openDataFolder() }; SettingsLink { Text("设置") }; Divider(); Button("退出 QQQMBar") { NSApplication.shared.terminate(nil) } } label: { Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).frame(width: 12, height: 24) }.menuStyle(.borderlessButton)
#endif
        }
        .frame(height: 56)
    }

    private func chartPanel(_ snapshot: QQQMSnapshot) -> some View {
        DashboardCard(tint: DashboardPalette.cyan) {
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("QQQM · 近 30 个交易日").font(.system(size: 10.5, weight: .semibold))
                        Text(snapshot.source.mode == .live ? "NASDAQ 收盘价" : "本地行情快照").font(.system(size: 6.3)).foregroundStyle(DashboardPalette.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(usd(snapshot.quote.lastPrice, decimals: 2)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(snapshot.quote.dayChangePct / 100, format: .percent.precision(.fractionLength(2))).font(.system(size: 7, weight: .semibold, design: .rounded))
                            .foregroundStyle(snapshot.quote.dayChangePct >= 0 ? DashboardPalette.green : DashboardPalette.coral)
                    }
                }
                HStack(spacing: 10) {
                    seriesLegend("价格", DashboardPalette.cyan)
                    seriesLegend("EMA20", DashboardPalette.orange)
                    tradeLegend("B", "买入 \(snapshot.buyMarkers.filter { $0.quantity > 0 }.count)", DashboardPalette.green)
                    tradeLegend("S", "卖出 \(snapshot.buyMarkers.filter { $0.quantity < 0 }.count)", DashboardPalette.coral)
                }
                .font(.system(size: 6.2, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                PriceChartView(snapshot: snapshot).frame(height: 110)
                HStack(spacing: 0) {
                    chartStat("区间低点", periodLow(snapshot), DashboardPalette.muted)
                    Divider().overlay(DashboardPalette.border)
                    chartStat("区间高点", periodHigh(snapshot), DashboardPalette.muted)
                    Divider().overlay(DashboardPalette.border)
                    chartStat("30 日涨跌", percent(periodReturn(snapshot)), periodReturn(snapshot) >= 0 ? DashboardPalette.green : DashboardPalette.coral)
                }
                .frame(height: 26)
            }
        }
        .frame(height: 202).clipped()
    }

    private func signalPanel(_ snapshot: QQQMSnapshot) -> some View {
        return DashboardCard(tint: DashboardPalette.steel) {
            HStack(spacing: 0) {
                signalTile(signal(snapshot, at: 0), tint: DashboardPalette.green).frame(width: 76)
                Divider().overlay(DashboardPalette.border)
                signalTile(signal(snapshot, at: 1), tint: DashboardPalette.purple).frame(width: 76)
                Divider().overlay(DashboardPalette.border)
                signalTile(signal(snapshot, at: 2), tint: DashboardPalette.orange).frame(width: 76)
                Divider().overlay(DashboardPalette.border)
                signalTile(signal(snapshot, at: 3), tint: DashboardPalette.blue).frame(width: 76)
            }
        }
        .frame(height: 76).clipped()
    }

    private func overviewPanels(_ snapshot: QQQMSnapshot) -> some View {
        let p = snapshot.portfolio
        return HStack(alignment: .top, spacing: 4) {
            DashboardCard(tint: DashboardPalette.green) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("QQQM 持仓").font(.system(size: 9, weight: .medium))
                        Spacer()
                        Text(percent(unrealizedPercent(snapshot)))
                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                            .foregroundStyle(snapshot.verifiedUnrealizedPnL >= 0 ? DashboardPalette.green : DashboardPalette.coral)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((snapshot.verifiedUnrealizedPnL >= 0 ? DashboardPalette.green : DashboardPalette.coral).opacity(0.14), in: Capsule())
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: "%.4f 股", p.shares)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("市值 \(usd(snapshot.verifiedMarketValue))").font(.system(size: 6.5)).foregroundStyle(DashboardPalette.muted)
                        }
                        Spacer(minLength: 2)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("未实现").font(.system(size: 6)).foregroundStyle(DashboardPalette.muted)
                            Text(signedUSD(snapshot.verifiedUnrealizedPnL)).font(.system(size: 8, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(snapshot.verifiedUnrealizedPnL >= 0 ? DashboardPalette.green : DashboardPalette.coral)
                    }
                    PositionCostVisualizer(averageCost: p.averageCost, currentPrice: snapshot.quote.lastPrice)
                }
            }.frame(width: DashboardLayout.halfCardWidth, height: 104).clipped()
            DashboardCard(tint: DashboardPalette.purple) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("账户概览").font(.system(size: 9, weight: .medium))
                        Spacer()
                        if snapshot.source.accountSource != nil {
                            Text("IBKR").font(.system(size: 5.8, weight: .bold)).foregroundStyle(DashboardPalette.green)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(DashboardPalette.green.opacity(0.13), in: Capsule())
                        }
                    }
                    HStack(spacing: 7) {
                        AllocationRing(qqqm: snapshot.verifiedPositionWeight, cash: snapshot.verifiedAvailableFundsWeight).frame(width: 50, height: 50)
                        VStack(alignment: .leading, spacing: 3) {
                            allocationLegend("QQQM", snapshot.verifiedPositionWeight, DashboardPalette.blue)
                            allocationLegend("可用资金", snapshot.verifiedAvailableFundsWeight, DashboardPalette.green)
                            allocationLegend("其余资产", max(0, 1 - snapshot.verifiedPositionWeight - snapshot.verifiedAvailableFundsWeight), DashboardPalette.purple)
                        }
                    }
                    HStack { Text("账户 NAV").foregroundStyle(DashboardPalette.muted); Spacer(); Text(usd(snapshot.verifiedNAV, decimals: 2)).fontWeight(.semibold) }.font(.system(size: 7))
                }
            }.frame(width: DashboardLayout.halfCardWidth, height: 104).clipped()
        }
    }

    private func bottomPanels(_ snapshot: QQQMSnapshot) -> some View {
        let p = snapshot.portfolio
        return HStack(alignment: .top, spacing: 4) {
            DashboardCard(tint: DashboardPalette.green) { VStack(alignment: .leading, spacing: 3) { Text("资金占比").font(.system(size: 8, weight: .medium)); ZStack { FundsGauge(value: snapshot.verifiedAvailableFundsWeight); Text(ratioPercent(snapshot.verifiedAvailableFundsWeight)).font(.system(size: 10, weight: .semibold, design: .rounded)) }.frame(width: 64, height: 32).clipped().frame(maxWidth: .infinity); pair("可用资金", usd(p.availableFunds)); tinyScale(snapshot.verifiedAvailableFundsWeight) } }.frame(width: DashboardLayout.thirdCardWidth)
            DashboardCard(tint: DashboardPalette.orange) { contributionHistory(snapshot) }.frame(width: DashboardLayout.thirdCardWidth)
            DashboardCard(tint: DashboardPalette.cyan) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("数据状态").font(.system(size: 8, weight: .medium))
                    HStack(spacing: 3) {
                        if model.isRefreshing { ProgressView().controlSize(.mini) }
                        else { Image(systemName: snapshot.auditIssues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(snapshot.auditIssues.isEmpty ? DashboardPalette.green : .orange) }
                        Text(model.isRefreshing ? "正在刷新" : (snapshot.auditIssues.isEmpty ? "市场数据已校验" : "\(snapshot.auditIssues.count) 项差异"))
                    }.font(.system(size: 7.5, weight: .medium)).lineLimit(1)
                    Text("\(snapshot.source.mode.label) · \(snapshot.lastUpdated.formatted(date: .numeric, time: .omitted))").font(.system(size: 6.5)).foregroundStyle(DashboardPalette.muted).lineLimit(1)
                    Divider().overlay(DashboardPalette.border)
                    HStack(spacing: 3) {
                        Image(systemName: snapshot.source.accountSource == nil ? "person.crop.circle" : "checkmark.shield.fill")
                        Text(snapshot.source.accountSource == nil ? "账户 · 本地快照" : "账户 · IBKR \(snapshot.source.accountAsOf?.formatted(date: .omitted, time: .shortened) ?? "已同步")")
                    }.font(.system(size: 6.2, weight: .medium)).foregroundStyle(snapshot.source.accountSource == nil ? DashboardPalette.muted : DashboardPalette.green).lineLimit(1)
                    HStack(spacing: 3) { Image(systemName: "lock.fill"); Text("只读 · 不下单") }.font(.system(size: 6.2, weight: .medium)).foregroundStyle(DashboardPalette.muted).lineLimit(1)
                }
            }.frame(width: DashboardLayout.thirdCardWidth)
        }
        .frame(height: 92).clipped()
    }

    @ViewBuilder private func confirmationButton(_ snapshot: QQQMSnapshot) -> some View {
        if model.planConfirmed {
            Label("本周计划已确认", systemImage: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 28)
                .foregroundStyle(DashboardPalette.ink).background(LinearGradient(colors: [DashboardPalette.green, DashboardPalette.cyan], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).layoutPriority(10).help("如需撤销，请使用右上角菜单中的“重新打开本周计划”。")
        } else {
            Button { model.confirmPlan() } label: { Label("确认本周计划 \(usd(snapshot.recommendation.recommendedAmount))", systemImage: "checkmark.circle").font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity) }
                .buttonStyle(.plain).foregroundStyle(DashboardPalette.ink).frame(height: 28)
                .background(LinearGradient(colors: [DashboardPalette.cyan, DashboardPalette.green], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                .layoutPriority(10)
                .help("仅记录计划确认；不会创建、提交或传输任何交易订单。")
        }
    }

    private var unavailable: some View {
        VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 25)).foregroundStyle(.orange); Text("快照不可用").font(.headline); Text(model.loadError ?? "请在设置中导入有效的 QQQM Snapshot。").font(.caption).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center); Button("重新读取") { model.reload() } }.foregroundStyle(DashboardPalette.text).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legend(_ text: String, _ color: Color, dot: Bool = false) -> some View { HStack(spacing: 3) { if dot { Circle().fill(color).frame(width: 5, height: 5) } else { Capsule().fill(color).frame(width: 8, height: 1.5) }; Text(text).font(.system(size: 6.5)).foregroundStyle(DashboardPalette.muted) } }
    private func tradeLegend(_ code: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(code).font(.system(size: 5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 10, height: 10).background(color, in: Circle())
            Text(text).foregroundStyle(DashboardPalette.muted)
        }
    }
    private func seriesLegend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 9, height: 1.5)
            Text(text).foregroundStyle(DashboardPalette.muted)
        }
    }
    private func contributionHistory(_ snapshot: QQQMSnapshot) -> some View {
        let recent = Array(snapshot.buyMarkers.filter { $0.quantity > 0 }.suffix(6))
        let maximum = recent.map(\.amount).max() ?? 1
        return VStack(alignment: .leading, spacing: 3) {
            Text("定投历史").font(.system(size: 8, weight: .medium))
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(recent) { marker in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DashboardPalette.blue.gradient)
                        .frame(height: max(3, 20 * CGFloat(marker.amount / maximum)))
                        .help("\(marker.date.formatted(date: .abbreviated, time: .omitted)) · \(usd(marker.amount, decimals: 2))")
                }
            }
            .frame(height: 20, alignment: .bottom)
            ForEach(Array(recent.suffix(3).reversed())) { marker in
                HStack(spacing: 2) {
                    Text(marketDate(marker.date))
                    Spacer()
                    Text(usd(marker.amount))
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DashboardPalette.green)
                }
                .font(.system(size: 6)).foregroundStyle(DashboardPalette.muted)
            }
        }
    }
    private func chartStat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 6.2)).foregroundStyle(DashboardPalette.muted)
            Text(value).font(.system(size: 8, weight: .semibold, design: .rounded)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
    }
    private func signalTile(_ item: MarketSignal, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) { Circle().fill(tint).frame(width: 4, height: 4); Text(item.title).font(.system(size: 6.5, weight: .medium)).foregroundStyle(DashboardPalette.muted).lineLimit(1) }
            Text(item.value).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.72)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashboardPalette.border.opacity(0.75))
                    Capsule().fill(tint.gradient).frame(width: proxy.size.width * CGFloat(min(max(item.normalized ?? 0, 0), 1)))
                }
            }.frame(height: 3)
            Text(item.source).font(.system(size: 5.8)).foregroundStyle(DashboardPalette.muted).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5)
    }
    private func signal(_ snapshot: QQQMSnapshot, at index: Int) -> MarketSignal {
        if snapshot.signals.indices.contains(index) { return snapshot.signals[index] }
        return MarketSignal(id: "missing-\(index)", title: "数据", value: "—", normalized: 0, source: "暂不可用", asOf: snapshot.lastUpdated, mode: snapshot.source.mode)
    }
    private func buyTimeline(_ snapshot: QQQMSnapshot) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(snapshot.buyMarkers.suffix(4))) { marker in
                VStack(spacing: 1) { Circle().fill(DashboardPalette.green).frame(width: 5, height: 5); Text(marker.date, format: .dateTime.month(.defaultDigits).day()).lineLimit(1); Text(usd(marker.amount)).lineLimit(1) }
                    .font(.system(size: 5.5)).foregroundStyle(DashboardPalette.muted).frame(maxWidth: .infinity)
            }
            VStack(spacing: 1) { Circle().fill(DashboardPalette.purple).frame(width: 5, height: 5); Text("计划"); Text(usd(snapshot.recommendation.recommendedAmount)) }
                .font(.system(size: 5.5)).foregroundStyle(DashboardPalette.muted).frame(maxWidth: .infinity)
        }
        .frame(height: 24)
    }
    private func chartSideStats(_ snapshot: QQQMSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("日内范围").font(.system(size: 6)).foregroundStyle(DashboardPalette.muted)
                HStack { Text(snapshot.quote.dayLow.map { usd($0, decimals: 2) } ?? "—"); Spacer(); Text(snapshot.quote.dayHigh.map { usd($0, decimals: 2) } ?? "—") }.font(.system(size: 6, weight: .medium))
                GeometryReader { proxy in ZStack { Capsule().fill(LinearGradient(colors: [DashboardPalette.green, .yellow, .red], startPoint: .leading, endPoint: .trailing)); if let low = snapshot.quote.dayLow, let high = snapshot.quote.dayHigh, high > low { Circle().fill(.white).frame(width: 4, height: 4).offset(x: proxy.size.width * CGFloat((snapshot.quote.lastPrice - low) / (high - low)) - 2) } } }.frame(height: 3)
            }
            Divider().overlay(DashboardPalette.border)
            VStack(alignment: .leading, spacing: 2) { Text("YTD 涨跌幅").font(.system(size: 6)).foregroundStyle(DashboardPalette.muted); Text(percent(snapshot.quote.ytdChangePct)).font(.system(size: 10, weight: .semibold)).foregroundStyle(DashboardPalette.green); Sparkline(values: Array(snapshot.priceHistory.map(\.close).suffix(8)), color: DashboardPalette.green).frame(height: 12) }
            Divider().overlay(DashboardPalette.border)
            VStack(alignment: .leading, spacing: 2) { Text("30日波动率(年化)").font(.system(size: 6)).foregroundStyle(DashboardPalette.muted); Text(snapshot.quote.annualizedVol30D.map { String(format: "%.1f%%", $0) } ?? "—").font(.system(size: 10, weight: .semibold)).foregroundStyle(DashboardPalette.purple); Sparkline(values: Array(snapshot.priceHistory.map(\.close).suffix(8).reversed()), color: DashboardPalette.purple).frame(height: 12) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    private func statusMetric(title: String, value: String, icon: String, tint: Color) -> some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 7, weight: .medium)).foregroundStyle(DashboardPalette.muted); Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint); Text(value).font(.system(size: 8, weight: .semibold)).lineLimit(1); Text(value == "未接入" ? "等待数据源" : "已载入快照").font(.system(size: 6)).foregroundStyle(DashboardPalette.muted).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func pair(_ title: String, _ value: String, _ tint: Color = DashboardPalette.text) -> some View { HStack { Text(title).foregroundStyle(DashboardPalette.muted); Spacer(minLength: 1); Text(value).foregroundStyle(tint).fontWeight(.medium) }.font(.system(size: 7)).lineLimit(1) }
    private func tinyScale(_ value: Double) -> some View { VStack(spacing: 1) { GeometryReader { proxy in ZStack(alignment: .leading) { Capsule().fill(DashboardPalette.border.opacity(0.8)); Capsule().fill(DashboardPalette.green).frame(width: proxy.size.width * min(max(value, 0.015), 1)) } }.frame(height: 3); HStack { Text("0%"); Spacer(); Text("25%"); Spacer(); Text("50%"); Spacer(); Text("100%") }.font(.system(size: 5)).foregroundStyle(DashboardPalette.muted) } }
    private func compactDays(_ date: Date) -> String { let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0; switch days { case ...(-1): return "已过期"; case 0: return "今天"; case 1: return "明天"; default: return "\(days) 天后" } }
    private func marketDate(_ date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = TimeZone(identifier: "America/New_York"); formatter.dateFormat = "M/d"; return formatter.string(from: date) }
    private func signalValue(_ snapshot: QQQMSnapshot, at index: Int) -> String { snapshot.signals.indices.contains(index) ? snapshot.signals[index].value : "未接入" }
    private func chartDates(_ snapshot: QQQMSnapshot) -> [Date] { let history = snapshot.priceHistory; guard !history.isEmpty else { return [] }; let indices = [0, history.count / 3, history.count * 2 / 3]; return indices.map { history[min($0, history.count - 1)].date } + [snapshot.recommendation.nextExecution] }
    private func allocationLegend(_ title: String, _ value: Double, _ tint: Color) -> some View { HStack(spacing: 3) { Circle().fill(tint).frame(width: 4, height: 4); Text(title).foregroundStyle(DashboardPalette.muted); Spacer(minLength: 1); Text(ratioPercent(value)).fontWeight(.medium) }.font(.system(size: 6.2)).lineLimit(1) }
    private func holdingMetric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 6)).foregroundStyle(DashboardPalette.muted); Text(value).font(.system(size: 8, weight: .medium, design: .rounded)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4) }
    private func periodLow(_ snapshot: QQQMSnapshot) -> String { snapshot.priceHistory.map(\.close).min().map { usd($0, decimals: 2) } ?? "—" }
    private func periodHigh(_ snapshot: QQQMSnapshot) -> String { snapshot.priceHistory.map(\.close).max().map { usd($0, decimals: 2) } ?? "—" }
    private func periodReturn(_ snapshot: QQQMSnapshot) -> Double { guard let first = snapshot.priceHistory.first?.close, let last = snapshot.priceHistory.last?.close, first > 0 else { return 0 }; return (last / first - 1) * 100 }
    private func costDeviation(_ snapshot: QQQMSnapshot) -> Double { let cost = snapshot.portfolio.averageCost; return cost > 0 ? (snapshot.quote.lastPrice / cost - 1) * 100 : 0 }
    private func percent(_ value: Double?) -> String { guard let value else { return "—" }; return String(format: "%+.2f%%", value) }
    private func ratioPercent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
    private func unrealizedPercent(_ snapshot: QQQMSnapshot) -> Double? { let basis = snapshot.portfolio.averageCost * snapshot.portfolio.shares; return basis > 0 ? snapshot.verifiedUnrealizedPnL / basis * 100 : nil }
    private func usd(_ amount: Double, decimals: Int = 0) -> String { let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"; formatter.currencySymbol = "$"; formatter.locale = Locale(identifier: "en_US"); formatter.minimumFractionDigits = decimals; formatter.maximumFractionDigits = decimals; return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.\(decimals)f", amount) }
    private func signedUSD(_ amount: Double) -> String { "\(amount >= 0 ? "+" : "−")\(usd(abs(amount), decimals: 2))" }
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

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var login = LoginItemController()
    @State private var importing = false
    var body: some View {
        Form {
            Section("常驻") { Toggle("登录后自动启动", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) })); if let message = login.message { Text(message).font(.caption).foregroundStyle(.red) } }
            Section("数据") {
                LabeledContent("当前数据", value: model.snapshot?.source.mode.label ?? "不可用")
                LabeledContent("更新时间", value: model.snapshot?.lastUpdated.formatted(date: .abbreviated, time: .shortened) ?? "—")
                LabeledContent("账户来源", value: model.snapshot?.source.accountSource ?? "本地快照")
                if let accountAsOf = model.snapshot?.source.accountAsOf { LabeledContent("账户同步", value: accountAsOf.formatted(date: .abbreviated, time: .shortened)) }
                LabeledContent("内部校验", value: model.snapshot.map { $0.auditIssues.isEmpty ? "通过" : "\($0.auditIssues.count) 项差异" } ?? "不可用")
                if let notes = model.snapshot?.source.notes { Text(notes).font(.caption).foregroundStyle(.secondary) }
                if let error = model.marketError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let issues = model.snapshot?.auditIssues, !issues.isEmpty { ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } }
                Button(model.isRefreshing ? "正在刷新…" : "立即刷新市场数据") { Task { await model.refreshMarketData() } }.disabled(model.isRefreshing)
                Button("导入账户快照…") { importing = true }; Button("打开数据文件夹") { model.openDataFolder() }
                Text("导入文件必须是 schemaVersion 2 的 QQQM 快照。当前 App 仅读取与展示数据，不含任何下单功能。").font(.caption).foregroundStyle(.secondary)
            }
            Section("安全") { Text("确认本周计划只保存本地确认记录，不会创建、提交或传输 IBKR 订单。").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding().frame(width: 450, height: 390)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in if case .success(let url) = result { model.importSnapshot(from: url) } }
    }
}

#if QQQMBAR_RENDER_TEST
private struct IconQAView: View {
    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 8) {
                RingBadge(confirmed: false, isRefreshing: false)
                RingBadge(confirmed: true, isRefreshing: false)
            }
            VStack(spacing: 8) {
                iconCell(Color(red: 0.16, green: 0.55, blue: 0.72), badge: DashboardPalette.purple)
                iconCell(Color.black.opacity(0.88), badge: DashboardPalette.green)
            }
        }
        .padding(18)
        .background(Color(red: 0.025, green: 0.065, blue: 0.115))
    }

    private func iconCell(_ background: Color, badge: Color) -> some View {
        ZStack {
            Image(nsImage: StatusGlyphImage.make(state: .pending))
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
            Circle().fill(badge).frame(width: 4, height: 4).offset(x: 8, y: -7)
        }
            .frame(width: 30, height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        let model = AppModel(previewSnapshot: snapshot)
        let iconsOnly = arguments.contains("--icons")
        let content = iconsOnly ? AnyView(IconQAView()) : AnyView(MenuPopoverView().environmentObject(model))
        let scheme: ColorScheme = arguments.contains("--light") ? .light : .dark
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
        renderer.proposedSize = iconsOnly ? ProposedViewSize(width: 154, height: 124) : ProposedViewSize(width: DashboardLayout.width, height: DashboardLayout.height)
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
        precondition(abs(snapshot.verifiedMarketValue - 1_392.459) < 0.001)
        precondition(abs(snapshot.verifiedUnrealizedPnL - (-1.1904)) < 0.001)
        precondition(abs(snapshot.verifiedNAV - 41_028.94) < 0.001)
        precondition(snapshot.quote.dayLow == 294.45 && snapshot.quote.dayHigh == 298.16)
        precondition(abs(snapshot.quote.dayChangePct - ((295.00 / 296.92 - 1) * 100)) < 0.0001)
        precondition(snapshot.signals.count == 4 && snapshot.signals.allSatisfy { $0.value != "未接入" })
        let ema = exponentialMovingAverage(snapshot.priceHistory, period: 20)
        precondition(ema.count == snapshot.priceHistory.count && ema.allSatisfy { $0.close.isFinite && $0.close > 0 })
        precondition(snapshot.recommendation.nextExecution.formatted(.iso8601) == "2026-09-01T13:30:00Z")
        let now = Date()
        let calendar = Calendar.current
        precondition(dcaReminderTitle(nextExecution: calendar.date(byAdding: .day, value: 2, to: now), confirmed: false, hasError: false, now: now) == "2天")
        precondition(dcaReminderTitle(nextExecution: calendar.date(byAdding: .day, value: 1, to: now), confirmed: false, hasError: false, now: now) == "明日")
        precondition(dcaReminderTitle(nextExecution: now, confirmed: false, hasError: false, now: now) == "今日")
        precondition(dcaReminderTitle(nextExecution: now, confirmed: true, hasError: false, now: now) == "✓")
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
        precondition(snapshot.auditIssues.isEmpty, "Live audit failed: \(snapshot.auditIssues.joined(separator: ", "))")
        precondition(snapshot.recommendation.id.hasPrefix("live-plan-"))
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
