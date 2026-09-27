import Foundation

/// Plan-quota data for Panda, matching what Panda Desktop's own
/// "我的用量" popover shows. Two acquisition paths produce this:
///
/// 1. CDP (automatic): a headless clone of the Panda Desktop binary is
///    launched with an isolated profile + `--remote-debugging-port`; its own
///    `window.pandaDesktop.quotaFetch()` runs inside the real app runtime and
///    returns the already-formatted structure (display strings, renewalText).
///    This path needs no token — auth state lives in ~/.panda regardless of
///    profile, and the safeStorage key comes from the shared Keychain entry.
///
/// 2. Direct API (manual token): `GET {authBaseUrl}/llm/quota/me` with a
///    user-pasted Bearer token; raw numeric fields (usedCredits, …).
public struct PandaQuotaSnapshot: Equatable, Sendable {
    public let planLabel: String
    public let usedCredits: Double
    public let creditLimit: Double
    public let remainingCredits: Double
    /// 0…100.
    public let usagePercent: Double
    /// "user" / "organization" / "none" — none means no plan at all.
    public let billingScope: String
    public let quotaStatus: String
    /// Formatted window text from the gateway, e.g. "2026-09-21 ～ 2026-09-28".
    public let periodText: String
    /// Formatted renewal line, e.g. "将于 2026年9月28日 刷新".
    public let renewalText: String
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
        periodText: String,
        renewalText: String,
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
        self.periodText = periodText
        self.renewalText = renewalText
        self.isUnlimited = isUnlimited
        self.fetchedAt = fetchedAt
    }

    public var hasPlan: Bool { billingScope != "none" && planLabel != "没套餐" }

    public enum Level: Sendable { case normal, warning, critical }
    public var level: Level {
        if usagePercent >= 100 { return .critical }
        if usagePercent >= 80 { return .warning }
        return .normal
    }

    public enum ParseError: Error, Equatable { case notJSON, noQuota }

    /// Parse either the gateway's raw response (`usedCredits`, …) or the
    /// Desktop-mapped structure (`usedCreditsDisplay`, …) that `quotaFetch()`
    /// returns. Numeric fields win when both are present.
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> PandaQuotaSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let payload: [String: Any] = (obj["data"] as? [String: Any]) ?? obj
        func str(_ key: String) -> String { payload[key] as? String ?? "" }
        func num(_ key: String) -> Double? {
            if let n = payload[key] as? NSNumber { return n.doubleValue }
            if let s = payload[key] as? String, let d = Double(s.replacingOccurrences(of: ",", with: "")) { return d }
            return nil
        }
        func display(_ key: String) -> Double? {
            guard let s = payload[key] as? String else { return nil }
            if s == "不限" { return -1 }
            return Double(s.replacingOccurrences(of: ",", with: ""))
        }

        guard payload["planLabel"] != nil || payload["usedCredits"] != nil || payload["usedCreditsDisplay"] != nil else {
            throw ParseError.noQuota
        }

        let used = num("usedCredits") ?? display("usedCreditsDisplay") ?? 0
        let limit = num("creditLimit") ?? display("creditLimitDisplay") ?? 0
        let remaining = num("remainingCredits") ?? display("remainingCreditsDisplay") ?? 0
        let isUnlimited = (payload["isUnlimited"] as? Bool) ?? (limit == -1)
        return PandaQuotaSnapshot(
            planLabel: str("planLabel"),
            usedCredits: used,
            creditLimit: limit,
            remainingCredits: remaining,
            usagePercent: num("usagePercent") ?? 0,
            billingScope: str("billingScope"),
            quotaStatus: str("quotaStatus"),
            periodText: str("periodText"),
            renewalText: str("renewalText"),
            isUnlimited: isUnlimited,
            fetchedAt: fetchedAt
        )
    }

    /// "16,971" / "不限" — mirrors the Desktop's s$ formatter.
    public func creditsDisplay(_ value: Double) -> String {
        if value < 0 { return "不限" }
        let rounded = Int(value.rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }
}
