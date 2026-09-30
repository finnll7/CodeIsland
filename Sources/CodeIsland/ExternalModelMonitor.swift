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
    private var lastActiveCWD: String?
    private var refreshTask: Task<Void, Never>?

    /// Faster cadence than the quota cards: a model switch must show up
    /// within seconds of the next event, and panel expansion always forces
    /// one (the user looking is the trigger). `activeCWD` = the session the
    /// user would look at — its workspace model record wins.
    func refreshIfStale(force: Bool = false, activeCWD: String? = nil) {
        if let activeCWD { lastActiveCWD = activeCWD }
        if !force, Date().timeIntervalSince(lastRefreshAt) < 15 { return }
        refresh()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        lastRefreshAt = Date()
        refreshTask = Task { [weak self] in
            // The active session's workspace decides which model record wins —
            // Panda keeps per-workspace model history, so switching models in
            // one task doesn't touch the global default.
            let cwd = await MainActor.run { self?.lastActiveCWD }
            let status = await Self.computeStatus(activeCWD: cwd)
            await MainActor.run {
                self?.externalModel = status
                self?.refreshTask = nil
            }
        }
    }
}

extension ExternalModelMonitor {
    /// Blocking I/O + keychain — runs off the main actor.
    ///
    /// Model resolution order:
    ///   1. the active session's workspace record (`modelRecent/...`) — what
    ///      the user picked for THIS task, even before any request runs;
    ///   2. the global default (`models.defaultModelId`) as fallback.
    /// Non-`custom:` ids (built-in gateway models) yield nil — the Panda plan
    /// card stays up for those.
    nonisolated static func computeStatus(activeCWD: String?) async -> ExternalModel? {
        let modelID = Self.currentCustomModelID(activeCWD: activeCWD)
        guard let modelID else { return nil }
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

    /// Pure resolution: workspace record first, global default second. Returns
    /// the bare custom-model uuid (without the `custom:` prefix) or nil.
    nonisolated static func currentCustomModelID(activeCWD: String?) -> String? {
        // 1) Workspace-scoped: the model last picked for this task.
        if let cwd = activeCWD, !cwd.isEmpty,
           let recordJSON = PandaTokenProvider.readWorkspaceModelId(cwd: cwd),
           let latest = Self.latestModelID(fromRecordJSON: recordJSON) {
            if latest.hasPrefix("custom:") {
                return String(latest.dropFirst("custom:".count))
            }
            return nil // built-in model selected for this workspace
        }
        // 2) Global default fallback (no active session / no record).
        guard let defaultModelID = PandaTokenProvider.readStateValue("models.defaultModelId"),
              defaultModelID.hasPrefix("custom:") else {
            return nil
        }
        return String(defaultModelID.dropFirst("custom:".count))
    }

    /// Newest `modelId` from a modelRecent JSON array (ordered newest-first;
    /// belt-and-braces: falls back to max(usedAt) when [0] isn't the newest).
    nonisolated static func latestModelID(fromRecordJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !entries.isEmpty else {
            return nil
        }
        let newest = entries.max { ($0["usedAt"] as? Double ?? 0) < ($1["usedAt"] as? Double ?? 0) }
        return (newest?["modelId"] as? String) ?? (entries.first?["modelId"] as? String)
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
