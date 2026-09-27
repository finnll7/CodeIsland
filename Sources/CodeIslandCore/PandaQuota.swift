import Foundation

/// Plan-quota data from the Panda gateway (`/llm/quota/me`), reverse-engineered
/// from Panda Desktop's own "我的用量" popover (quotaRuntime.fetch → WLt mapper).
/// Field semantics verified against the Desktop renderer:
///   planLabel "二档套餐", usedCredits 16971 → "16,971",
///   creditLimit 35000, usagePercent 48, remainingCredits 18029,
///   windowEndLabel "2026-09-28" → "将于 2026年9月28日 刷新".
public struct PandaQuotaSnapshot: Equatable, Sendable {
    public let planLabel: String
    /// Numeric credits (used / limit / remaining). `creditLimit == -1` means unlimited.
    public let usedCredits: Double
    public let creditLimit: Double
    public let remainingCredits: Double
    /// 0…100 as reported by the gateway (already computed from used/limit).
    public let usagePercent: Double
    /// "user" / "organization" / "none" — none means no plan at all.
    public let billingScope: String
    public let quotaStatus: String
    /// Window end as a raw label ("2026-09-28"); displayed verbatim.
    public let windowEndLabel: String
    public let isUnlimited: Bool
    public let fetchedAt: Date

    public init(
        planLabel: String,
        usedCredits: Double,
        creditLimit: Double,
        remainingCredits: Double,
        usagePercent: Double,
        billingScope: String,
        quotaStatus: String,
        windowEndLabel: String,
        isUnlimited: Bool,
        fetchedAt: Date
    ) {
        self.planLabel = planLabel
        self.usedCredits = usedCredits
        self.creditLimit = creditLimit
        self.remainingCredits = remainingCredits
        self.usagePercent = usagePercent
        self.billingScope = billingScope
        self.quotaStatus = quotaStatus
        self.windowEndLabel = windowEndLabel
        self.isUnlimited = isUnlimited
        self.fetchedAt = fetchedAt
    }

    public var hasPlan: Bool { billingScope != "none" && planLabel != "没套餐" }

    /// Severity bucket for footer colouring.
    public enum Level: Sendable { case normal, warning, critical }
    public var level: Level {
        if usagePercent >= 100 { return .critical }
        if usagePercent >= 80 { return .warning }
        return .normal
    }

    public enum ParseError: Error, Equatable { case notJSON, noQuota }

    /// Parse the `/llm/quota/me` response (field names per Jbn normaliser).
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> PandaQuotaSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        // Some gateways wrap in { data: {...} } — unwrap one level.
        let payload: [String: Any] = (obj["data"] as? [String: Any]) ?? obj
        func num(_ key: String) -> Double {
            if let n = payload[key] as? NSNumber { return n.doubleValue }
            if let s = payload[key] as? String, let d = Double(s.replacingOccurrences(of: ",", with: "")) { return d }
            return 0
        }
        func str(_ key: String) -> String { payload[key] as? String ?? "" }
        guard payload["planLabel"] != nil || payload["usedCredits"] != nil else {
            throw ParseError.noQuota
        }
        return PandaQuotaSnapshot(
            planLabel: str("planLabel"),
            usedCredits: num("usedCredits"),
            creditLimit: num("creditLimit"),
            remainingCredits: num("remainingCredits"),
            usagePercent: num("usagePercent"),
            billingScope: str("billingScope"),
            quotaStatus: str("quotaStatus"),
            windowEndLabel: str("windowEndLabel"),
            isUnlimited: (payload["isUnlimited"] as? Bool) ?? (num("creditLimit") == -1),
            fetchedAt: fetchedAt
        )    }

    /// "16,971" / "不限" — mirrors the Desktop's s$ formatter.
    public func creditsDisplay(_ value: Double) -> String {
        if value < 0 { return "不限" }
        let rounded = Int(value.rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }
}
