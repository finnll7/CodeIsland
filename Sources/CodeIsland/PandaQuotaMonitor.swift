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

/// Drives `window.pandaDesktop.quotaFetch()` over CDP. Three acquisition
/// strategies, tried in order:
///
/// 1. **Already-running instance**: if the user's live Panda Desktop carries
///    `--remote-debugging-port` (e.g. via the launcher patch below), connect
///    to it directly — zero process spawn.
/// 2. **Short-lived clone**: launch the binary with an isolated profile +
///    random DevTools port, run the same evaluate, then terminate. Auth
///    state lives in ~/.panda (profile independent) and the safeStorage key
///    in the shared Keychain entry, so the clone is logged in without any
///    user action.
/// Both end up in `evaluateQuota` on the app's own page target.
public enum PandaQuotaCDP {
    public static let pandaBinary = "/Applications/Panda 桌面版.app/Contents/MacOS/Panda 桌面版"
    /// Binary name the launcher patch renames the original to.
    public static let patchedBinaryName = "Panda 桌面版.bin"
    /// Port the launcher patch pins.
    public static let launcherPatchPort = 19222

    public static func fetch(timeout: TimeInterval = 45) async throws -> PandaQuotaSnapshot {
        // 1. Live instance with a debug port — connect straight to it.
        if let port = PandaProcessScanner.findRunningDebugPort() {
            do {
                let deadline = Date().addingTimeInterval(15)
                let wsURL = try await waitForPageTarget(port: port, deadline: deadline)
                return try await evaluateQuota(wsURL: wsURL, deadline: deadline)
            } catch {
                // Fall through to the clone path — the live instance may be
                // mid-restart or the port stale.
            }
        }

        // 2. Short-lived clone with an isolated profile.
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

/// Finds a DevTools port on an already-running Panda Desktop process.
/// The command line is public information (KERN_PROCARGS2 is readable for
/// same-user processes), so this costs no special entitlements.
public enum PandaProcessScanner {
    /// Scans `ps` output for the Panda main process and its
    /// `--remote-debugging-port=N` argument. Returns the first hit.
    public static func findRunningDebugPort() -> Int? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            // Only the app's own main binary — helpers don't carry the flag.
            guard line.contains("Panda 桌面版.app/Contents/MacOS"),
                  !line.contains("--type=") else { continue }
            if let range = line.range(of: #"--remote-debugging-port=(\d+)"#,
                                      options: .regularExpression) {
                let digits = line[range].dropFirst("--remote-debugging-port=".count)
                if let port = Int(digits), port > 0 { return port }
            }
        }
        return nil
    }
}

/// One-time launcher patch: renames Panda's real binary to
/// `<name>.bin` and drops a small script in its place that re-execs it with
/// `--remote-debugging-port` pinned. After the patch, every Panda launch —
/// login item, Dock, `open -a` — carries a DevTools port, so quota queries
/// attach to the live instance and never spawn a clone.
///
/// A Panda update rewrites the bundle and un-does the patch; `isApplied`
/// detects that and the setting can simply be re-toggled.
public enum PandaLauncherPatch {
    private static let appMacOSDir = "/Applications/Panda 桌面版.app/Contents/MacOS"
    private static var binaryPath: String { appMacOSDir + "/Panda 桌面版" }
    private static var binPath: String { appMacOSDir + "/" + PandaQuotaCDP.patchedBinaryName }
    private static var launcherPath: String { appMacOSDir + "/Panda 桌面版" }

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binPath)
            || FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    /// Patched when the launcher script exists AND the renamed binary exists.
    public static var isApplied: Bool {
        guard let kind = try? FileManager.default.attributesOfItem(atPath: launcherPath)[.type] as? FileAttributeType,
              kind == .typeRegular
        else { return false }
        // A patched launcher is a small text file; the original binary is Mach-O.
        if let data = FileManager.default.contents(atPath: launcherPath),
           let head = String(data: data.prefix(2), encoding: .utf8) {
            return head == "#!" && FileManager.default.isExecutableFile(atPath: binPath)
        }
        return false
    }

    @discardableResult
    public static func apply() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaryPath) else { return false }
        guard !isApplied else { return true }
        // Recover from a half-applied state before renaming.
        if fm.fileExists(atPath: launcherPath), !fm.isExecutableFile(atPath: binPath) {
            // launcherPath is the real binary again (update overwrote us).
        }
        do {
            if fm.fileExists(atPath: binPath) { try fm.removeItem(atPath: binPath) }
            try fm.moveItem(atPath: binaryPath, toPath: binPath)
        } catch {
            return false
        }
        let script = """
        #!/bin/bash
        # CodeIsland launcher patch — re-execs the real Panda binary with a
        # DevTools port so quota queries attach to the running instance.
        DIR="$(cd "$(dirname "$0")" && pwd)"
        exec "$DIR/\(PandaQuotaCDP.patchedBinaryName)" --remote-debugging-port=\(PandaQuotaCDP.launcherPatchPort) "$@"
        """
        guard fm.createFile(atPath: launcherPath, contents: Data(script.utf8),
                            attributes: [.posixPermissions: 0o755]) else {
            // Roll the rename back — never leave the app without its binary.
            try? fm.moveItem(atPath: binPath, toPath: binaryPath)
            return false
        }
        return true
    }

    @discardableResult
    public static func remove() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binPath) else { return true }
        do {
            if fm.fileExists(atPath: launcherPath) { try fm.removeItem(atPath: launcherPath) }
            try fm.moveItem(atPath: binPath, toPath: binaryPath)
            return true
        } catch {
            return false
        }
    }
}
