import AppKit
import CodeIslandCore
import Foundation

/// Tracks Panda's currently selected model and, when it is an EXTERNAL
/// ("custom") model, surfaces that model's provider balance instead of the
/// Panda plan card.
///
/// Data sources (all read-only, same state.db the token probe uses):
///   - state_kv.models.defaultModelId  — the selected model id
///     ("ecloud_…" = built-in, "custom:<uuid>" = external);
///   - state_kv.models.custom.v1       — external model definitions
///     (providerPreset / baseUrl / name);
///   - secret_kv.panda.model.custom.apiKey.<modelID> — decrypted via the
///     Panda Safe Storage keyring.
///
/// Balance endpoints are provider-specific: DeepSeek exposes GET /user/balance
/// (total balance in CNY); most other providers have no public endpoint, in
/// which case the card shows the model without a balance figure.
@MainActor
@Observable
final class ExternalModelMonitor {
    struct ExternalModel: Equatable {
        let modelID: String
        let name: String
        let provider: String
        let balanceText: String?
    }

    /// Non-nil while an external model is the selected one.
    private(set) var externalModel: ExternalModel?

    var isLive: Bool { externalModel != nil }

    private var lastRefreshAt = Date.distantPast
    private var refreshTask: Task<Void, Never>?

    /// Same cadence as the quota cards: panel expansion / Stop events.
    /// `force` bypasses the 120s throttle (used on system wake).
    func refreshIfStale(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastRefreshAt) < 120 { return }
        refresh()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        lastRefreshAt = Date()
        refreshTask = Task { [weak self] in
            let status = await Self.computeStatus()
            await MainActor.run {
                self?.externalModel = status
                self?.refreshTask = nil
            }
        }
    }
}

extension ExternalModelMonitor {
    /// Blocking I/O + keychain — runs off the main actor.
    nonisolated static func computeStatus() async -> ExternalModel? {
        guard let defaultModelID = PandaTokenProvider.readStateValue("models.defaultModelId"),
              defaultModelID.hasPrefix("custom:") else {
            return nil
        }
        let modelID = String(defaultModelID.dropFirst("custom:".count))
        guard let customJSON = PandaTokenProvider.readStateValue("models.custom.v1"),
              let data = customJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return nil
        }
        let definition = models.first { ($0["id"] as? String)?.hasSuffix(modelID) == true }
        guard let definition else { return nil }

        let provider = definition["providerPreset"] as? String ?? "openai"
        let name = definition["name"] as? String
            ?? (definition["model"] as? String)
            ?? modelID

        var balanceText: String?
        if provider == "deepseek",
           let key = PandaTokenProvider.readCustomModelKey(modelID: modelID),
           let balance = await Self.fetchDeepSeekBalance(apiKey: key) {
            balanceText = balance
        }
        return ExternalModel(modelID: modelID, name: name, provider: provider, balanceText: balanceText)
    }

    /// DeepSeek's official balance endpoint: total balance in the account
    /// currency (CNY for api.deepseek.com accounts). There is no public
    /// per-day usage endpoint — the balance is what the API offers.
    nonisolated static func fetchDeepSeekBalance(apiKey: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balanceInfos = root["balance_infos"] as? [[String: Any]],
              let first = balanceInfos.first else {
            return nil
        }
        let currency = first["currency"] as? String ?? "CNY"
        let total = first["total_balance"] as? String ?? "?"
        let symbol = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : "\(currency) ")
        return "\(symbol)\(total)"
    }
}
