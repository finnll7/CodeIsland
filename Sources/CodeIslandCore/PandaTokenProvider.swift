import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Security

/// Zero-intrusion automatic retrieval of the Panda gateway access token.
///
/// Reads only:
///   1. the Keychain generic password Panda Desktop itself created
///      ("Panda Safe Storage" / "Panda") — macOS shows a one-time consent
///      dialog, "Always Allow" makes it silent forever;
///   2. `~/.panda/data/state.db` → `secret_kv.auth.accessToken`.
///
/// Nothing in Panda is written, launched, patched or restarted. The cipher
/// parameters (scrypt + AES-128-CBC + "v12"+base64 framing) were extracted
/// from Panda Desktop's own `SharedEncryption` class:
///   key  = scryptSync(keychainPassword, "saltysalt", 16)   // N=16384, r=8, p=1
///   iv   = 16 × 0x20
///   ct   = "v12" || base64(AES-128-CBC(key, iv, plaintext))
public enum PandaTokenProvider {
    private static let serviceName = "Panda Safe Storage"
    private static let accountName = "Panda"
    private static let stateDBPath = NSHomeDirectory() + "/.panda/data/state.db"

    public enum TokenError: LocalizedError, Equatable {
        case keychainUnavailable(String)
        case stateDBUnavailable
        case tokenNotStored
        case cryptoFailure

        public var errorDescription: String? {
            switch self {
            case .keychainUnavailable: return "Panda 钥匙串条目不可用（需在授权弹窗中点击\"始终允许\"）"
            case .stateDBUnavailable: return "未找到 Panda 的 state.db"
            case .tokenNotStored: return "Panda 未存储访问令牌（请先登录 Panda）"
            case .cryptoFailure: return "令牌解密失败（钥匙串密码与密文不匹配）"
            }
        }
    }

    /// Fast, non-throwing probe: auto-retrieval is worth attempting when the
    /// Panda state db exists (Keychain consent is asked lazily on first read).
    public static var isAutoFetchPlausible: Bool {
        FileManager.default.fileExists(atPath: stateDBPath)
    }

    /// Full automatic retrieval. Blocking I/O — call off the main actor.
    public static func fetchToken() throws -> String {
        let password = try keychainPassword()
        let encrypted = try readEncryptedToken()
        return try decrypt(encryptedValue: encrypted, keyringPassword: password)
    }

    // MARK: - Keychain

    private static func keychainPassword() throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw TokenError.keychainUnavailable("status \(status)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - SQLite (read-only)

    private static func readEncryptedToken() throws -> String {
        guard FileManager.default.fileExists(atPath: stateDBPath) else {
            throw TokenError.stateDBUnavailable
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw TokenError.stateDBUnavailable
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT encrypted_value FROM secret_kv WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw TokenError.tokenNotStored
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "auth.accessToken", -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else {
            throw TokenError.tokenNotStored
        }
        return String(cString: cString)
    }

    // MARK: - Cipher

    private static func decrypt(encryptedValue: String, keyringPassword: String) throws -> String {
        guard encryptedValue.hasPrefix("v12"), encryptedValue.count > 3 else {
            throw TokenError.cryptoFailure
        }
        guard let ciphertext = Data(base64Encoded: String(encryptedValue.dropFirst(3))) else {
            throw TokenError.cryptoFailure
        }
        let key = try Scrypt.derive(
            password: Array(keyringPassword.utf8),
            salt: Array("saltysalt".utf8),
            N: 16384, r: 8, p: 1,
            dkLen: 16
        )
        let iv = [UInt8](repeating: 0x20, count: 16)

        guard key.count == kCCKeySizeAES128, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw TokenError.cryptoFailure
        }
        var out = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), UInt32(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            Array(ciphertext), ciphertext.count,
            &out, out.count, &outLen
        )
        guard status == kCCSuccess else { throw TokenError.cryptoFailure }
        let plain = Data(out.prefix(outLen))
        guard let token = String(data: plain, encoding: .utf8), !token.isEmpty else {
            throw TokenError.cryptoFailure
        }
        return token
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
