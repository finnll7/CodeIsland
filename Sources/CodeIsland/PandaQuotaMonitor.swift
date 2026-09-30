import CodeIslandCore
import Foundation

/// Fetches the Panda plan-quota snapshot from the gateway. Simplified sibling
/// of `ClaudeQuotaMonitor`: same event-driven surface (expand / collapse /
/// stop), throttled to one fetch per 120 s.
///
/// The gateway token comes from Settings when pasted, otherwise it is
/// auto-retrieved read-only from the local Panda state (Keychain + state.db,
/// see `PandaTokenProvider`). Because that keychain read can block on a
/// consent prompt nobody answers, a stuck fetch must not freeze the monitor:
/// a watchdog releases the flight lock after `staleFlightTimeout`.
@MainActor
@Observable
final class PandaQuotaMonitor {
    private(set) var snapshot: PandaQuotaSnapshot?
    private(set) var lastError: String?
    private(set) var isExpanded = false

    @ObservationIgnored private var inFlight = false
    /// Monotonic fetch id: a superseded fetch (released by the watchdog, then
    /// replaced) must not clobber a newer one's state when it finally lands.
    @ObservationIgnored private var fetchGeneration = 0
    /// A Stop arrived since the last completed fetch — credits were booked
    /// server-side, so the next expand must fetch even inside the 120 s
    /// throttle (covers the common case: work finishes while collapsed).
    @ObservationIgnored private var stopSinceLastFetch = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetcher: @Sendable () async throws -> PandaQuotaSnapshot
    @ObservationIgnored private let staleFlightTimeout: TimeInterval

    init(
        defaults: UserDefaults = .standard,
        staleFlightTimeout: TimeInterval = 60,
        fetcher: @escaping @Sendable () async throws -> PandaQuotaSnapshot = {
            let manualToken = (UserDefaults.standard.string(forKey: SettingsKey.pandaGatewayToken) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Keychain read + scrypt (16 MB memory) run off the main actor.
            let token = manualToken.isEmpty ? try PandaTokenProvider.fetchToken() : manualToken
            let base = UserDefaults.standard.string(forKey: SettingsKey.pandaGatewayBaseURL) ?? PandaQuotaClient.defaultBaseURL
            return try await PandaQuotaClient.fetch(token: token, baseURL: base)
        }
    ) {
        self.defaults = defaults
        self.staleFlightTimeout = staleFlightTimeout
        self.fetcher = fetcher
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
        if stopSinceLastFetch || snapshot == nil {
            fetchNow()
            return
        }
        if let fetchedAt = snapshot?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 120 { return }
        fetchNow()
    }

    func noteCollapsed() {
        isExpanded = false
    }

    /// A finished turn may have consumed credits — refresh opportunistically.
    /// While collapsed the footer is invisible, so the refresh is deferred to
    /// the next expand rather than hitting the keychain in the background.
    func noteStop() {
        guard isEnabled, isConfigured else { return }
        stopSinceLastFetch = true
        guard isExpanded, !inFlight else { return }
        fetchNow()
    }

    /// Kick off one fetch immediately (respects an in-flight request).
    func fetchNow() {
        guard !inFlight, isEnabled, isConfigured else { return }
        inFlight = true
        fetchGeneration += 1
        let generation = fetchGeneration
        let fetcher = self.fetcher
        Task { [weak self] in
            let result: Result<PandaQuotaSnapshot, Error>
            do {
                result = .success(try await fetcher())
            } catch {
                result = .failure(error)
            }
            self?.apply(result, generation: generation)
        }
        // Watchdog: the token retrieval can block on a keychain consent
        // prompt nobody answers; release the flight lock after a grace
        // period so later expands retry instead of freezing forever.
        let timeout = staleFlightTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.releaseStaleFlight(generation: generation)
        }
    }

    private func apply(_ result: Result<PandaQuotaSnapshot, Error>, generation: Int) {
        guard generation == fetchGeneration else { return }
        inFlight = false
        stopSinceLastFetch = false
        switch result {
        case .success(let snap):
            snapshot = snap
            lastError = nil
            // Tiered balance alerts (≤40/20/10% remaining, one shot per tier).
            QuotaAlertNotifier.check(snapshot: snap)
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    private func releaseStaleFlight(generation: Int) {
        guard generation == fetchGeneration, inFlight else { return }
        inFlight = false
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
