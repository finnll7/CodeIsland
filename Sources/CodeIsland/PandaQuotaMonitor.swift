import CodeIslandCore
import Foundation

/// Fetches the Panda plan-quota snapshot from the gateway. Simplified sibling
/// of `ClaudeQuotaMonitor`: same event-driven surface (expand / collapse /
/// stop), throttled to one fetch per 120 s. The gateway token is supplied by
/// the user in Settings (Panda stores it safeStorage-encrypted in its own
/// state db, which we deliberately do not read).
@MainActor
@Observable
final class PandaQuotaMonitor {
    private(set) var snapshot: PandaQuotaSnapshot?
    private(set) var lastError: String?
    private(set) var isExpanded = false

    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Gateway access token pasted by the user in Settings. When empty the
    /// monitor falls back to automatic retrieval from the local Panda state
    /// (read-only: Keychain + state.db, see `PandaTokenProvider`).
    var token: String {
        let raw = defaults.string(forKey: SettingsKey.pandaGatewayToken) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEnabled: Bool {
        defaults.bool(forKey: SettingsKey.showPandaQuota)
    }

    /// A fetch can proceed: either a manual token exists or the local Panda
    /// auto-retrieval path is plausible (its state db is present).
    var isConfigured: Bool {
        !token.isEmpty || PandaTokenProvider.isAutoFetchPlausible
    }

    func noteExpanded() {
        isExpanded = true
        guard isEnabled, isConfigured else { return }
        if let fetchedAt = snapshot?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 120 { return }
        fetchNow()
    }

    func noteCollapsed() {
        isExpanded = false
    }

    /// A finished turn may have consumed credits — refresh opportunistically.
    func noteStop() {
        guard isEnabled, isConfigured, isExpanded else { return }
        if let fetchedAt = snapshot?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 120 { return }
        fetchNow()
    }

    func fetchNow() {
        guard !inFlight, isEnabled, isConfigured else { return }
        inFlight = true
        let manualToken = self.token
        let baseURL = defaults.string(forKey: SettingsKey.pandaGatewayBaseURL) ?? PandaQuotaClient.defaultBaseURL
        Task { [weak self] in
            let result: Result<PandaQuotaSnapshot, Error>
            do {
                // Keychain read + scrypt (16 MB memory) run off the main actor.
                let resolved = manualToken.isEmpty ? try PandaTokenProvider.fetchToken() : manualToken
                result = .success(try await PandaQuotaClient.fetch(token: resolved, baseURL: baseURL))
            } catch {
                result = .failure(error)
            }
            self?.apply(result)
        }
    }

    private func apply(_ result: Result<PandaQuotaSnapshot, Error>) {
        inFlight = false
        switch result {
        case .success(let snap):
            snapshot = snap
            lastError = nil
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }
}

extension PandaQuotaMonitor {
    /// Debug harness / tests: inject a snapshot without any fetch.
    func applyPreview(_ snap: PandaQuotaSnapshot) {
        snapshot = snap
        lastError = nil
    }
}

/// Gateway client. Endpoint and headers reverse-engineered from Panda
/// Desktop's quotaRuntime (`GET {authBaseUrl}/llm/quota/me`, Bearer auth).
public enum PandaQuotaClient {
    /// Default gateway base — overridable for on-prem deployments.
    public static let defaultBaseURL = "https://panda.cdcyy.cn:10443"

    public static func fetch(
        token: String,
        baseURL: String,
        timeout: TimeInterval = 15
    ) async throws -> PandaQuotaSnapshot {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        // Panda Desktop builds the quota URL via Oc() which inserts an /api
        // prefix: {authBaseUrl}/api/llm/quota/me. Tolerate bases that already
        // carry it.
        let path = base.hasSuffix("/api") ? "/llm/quota/me" : "/api/llm/quota/me"
        guard let url = URL(string: base + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 401:
                throw PandaQuotaError.unauthorized
            default:
                throw PandaQuotaError.http(http.statusCode)
            }
        }
        return try PandaQuotaSnapshot.parse(data)
    }
}

public enum PandaQuotaError: LocalizedError, Equatable {
    case unauthorized
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Panda 网关 Token 无效或已过期"
        case .http(let code): return "Panda 网关返回 \(code)"
        }
    }
}
