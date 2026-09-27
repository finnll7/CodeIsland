import CodeIslandCore
import Foundation

/// Fetches the Panda plan-quota snapshot. Two modes:
///
/// - **CDP (default, fully automatic)**: launches a short-lived clone of the
///   Panda Desktop binary with an isolated profile and a random DevTools
///   port, then drives its own `window.pandaDesktop.quotaFetch()` over the
///   Chrome DevTools Protocol. Auth state lives in ~/.panda (profile
///   independent) and the safeStorage key in the shared Keychain entry, so
///   the clone is logged in without any user action. Needs no token.
/// - **Direct API**: when the user pasted a gateway token in Settings, the
///   gateway is queried directly (`/llm/quota/me`, Bearer auth).
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

    /// Gateway access token pasted by the user in Settings (optional fallback
    /// / direct path — the CDP path needs nothing).
    var token: String {
        let raw = defaults.string(forKey: SettingsKey.pandaGatewayToken) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEnabled: Bool {
        defaults.bool(forKey: SettingsKey.showPandaQuota)
    }

    var isConfigured: Bool { true }

    func noteExpanded() {
        isExpanded = true
        guard isEnabled else { return }
        if let fetchedAt = snapshot?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 120 { return }
        fetchNow()
    }

    func noteCollapsed() {
        isExpanded = false
    }

    /// A finished turn may have consumed credits — refresh opportunistically.
    func noteStop() {
        guard isEnabled, isExpanded else { return }
        if let fetchedAt = snapshot?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < 120 { return }
        fetchNow()
    }

    func fetchNow() {
        guard !inFlight else { return }
        inFlight = true
        let useToken = !token.isEmpty
        let token = self.token
        let baseURL = defaults.string(forKey: SettingsKey.pandaGatewayBaseURL) ?? PandaQuotaClient.defaultBaseURL
        Task { [weak self] in
            let result: Result<PandaQuotaSnapshot, Error>
            do {
                let snap = useToken
                    ? try await PandaQuotaClient.fetch(token: token, baseURL: baseURL)
                    : try await PandaQuotaCDP.fetch()
                result = .success(snap)
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

/// Direct gateway client. Endpoint and headers reverse-engineered from Panda
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
        guard let url = URL(string: base + "/llm/quota/me") else {
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

/// Drives a short-lived Panda Desktop clone over CDP to run its own
/// `quotaFetch()` — see `PandaQuotaMonitor` for the rationale.
public enum PandaQuotaCDP {
    public static let pandaBinary = "/Applications/Panda 桌面版.app/Contents/MacOS/Panda 桌面版"

    public static func fetch(timeout: TimeInterval = 45) async throws -> PandaQuotaSnapshot {
        guard FileManager.default.isExecutableFile(atPath: pandaBinary) else {
            throw PandaQuotaError.pandaNotFound
        }
        let port = Int.random(in: 20000...59999)
        let profile = NSTemporaryDirectory() + "panda-quota-profile-\(port)-\(Int.random(in: 100...999))"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pandaBinary)
        proc.arguments = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profile)",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        defer {
            if proc.isRunning { proc.terminate() }
            // Give the helper processes a beat, then sweep the temp profile.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                try? FileManager.default.removeItem(atPath: profile)
            }
        }

        // A Panda window would flash over the user's desktop — hide the clone.
        hideWindows(pid: proc.processIdentifier)

        let deadline = Date().addingTimeInterval(timeout)
        let wsURL = try await waitForPageTarget(port: port, deadline: deadline)
        return try await evaluateQuota(wsURL: wsURL, deadline: deadline)
    }

    /// Poll `/json/list` until the app window's page target appears.
    private static func waitForPageTarget(port: Int, deadline: Date) async throws -> URL {
        var lastError: Error = PandaQuotaError.cdpTimeout
        while Date() < deadline {
            do {
                let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
                let (data, _) = try await URLSession.shared.data(from: url)
                let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                if let page = targets.first(where: { ($0["type"] as? String) == "page" }),
                   let ws = page["webSocketDebuggerUrl"] as? String,
                   let url = URL(string: ws) {
                    return url
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw lastError
    }

    /// One CDP session: `Runtime.evaluate` on `window.pandaDesktop.quotaFetch()`.
    private static func evaluateQuota(wsURL: URL, deadline: Date) async throws -> PandaQuotaSnapshot {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: wsURL)
        task.resume()

        func send(_ payload: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await task.send(.data(data))
        }
        func receiveUntil(_ deadline: Date) async throws -> [String: Any] {
            while Date() < deadline {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
            }
            throw PandaQuotaError.cdpTimeout
        }

        // Runtime.enable then the evaluate; responses matched by id.
        try await send(["id": 1, "method": "Runtime.enable", "params": [:]])
        let expression = "window.pandaDesktop.quotaFetch().then(d => JSON.stringify(d))"
        try await send([
            "id": 2,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true, "returnByValue": true],
        ])

        var quotaJSON: String?
        while Date() < deadline {
            let obj = try await receiveUntil(deadline)
            guard let id = obj["id"] as? Int else { continue }
            if id == 2 {
                if let error = obj["error"] as? [String: Any] {
                    throw PandaQuotaError.cdpProtocol((error["message"] as? String) ?? "evaluate failed")
                }
                let result = obj["result"] as? [String: Any]
                let value = result?["result"] as? [String: Any]
                if let json = value?["value"] as? String, !json.isEmpty {
                    quotaJSON = json
                }
                break
            }
        }
        task.cancel(with: .normalClosure, reason: nil)
        guard let quotaJSON, !quotaJSON.isEmpty, quotaJSON != "null" else {
            throw PandaQuotaError.cdpProtocol("quotaFetch returned no data")
        }
        return try PandaQuotaSnapshot.parse(Data(quotaJSON.utf8))
    }

    /// Best-effort: hide the clone's windows so the fetch is unobtrusive.
    private static func hideWindows(pid: pid_t) {
        DispatchQueue.global().async {
            let script = """
            tell application "System Events" to set visible of ¬
                (first application process whose unix id is \(pid)) to false
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
    }
}

public enum PandaQuotaError: LocalizedError, Equatable {
    case unauthorized
    case http(Int)
    case pandaNotFound
    case cdpTimeout
    case cdpProtocol(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Panda 网关 Token 无效或已过期"
        case .http(let code): return "Panda 网关返回 \(code)"
        case .pandaNotFound: return "未找到 Panda 桌面版（/Applications/Panda 桌面版.app）"
        case .cdpTimeout: return "Panda 套餐查询超时"
        case .cdpProtocol(let message): return "Panda 套餐查询失败：\(message)"
        }
    }
}
