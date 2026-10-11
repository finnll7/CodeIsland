import XCTest
@testable import CodeIslandCore

/// Offline vectors for the two SharedEncryption framings Panda writes into
/// `state.db.secret_kv`. The v13 vector was produced with Panda Desktop's own
/// parameters (scrypt → AES-256-GCM, key name bound as AAD) and must keep
/// decrypting as the format evolves.
final class PandaTokenProviderDecryptTests: XCTestCase {
    private let password = "test-keyring-password"

    /// v12 — scrypt(pw, "saltysalt", 16) + AES-128-CBC, fixed 0x20 IV.
    func testDecryptV12() throws {
        // Fixed vector: encrypt("legacy-token") with the v12 parameters above.
        let encrypted = "v12Cqmmz8KHBNuxcQO4/TwQSA=="
        let token = try PandaTokenProvider.decryptForTesting(
            encryptedValue: encrypted, keyringPassword: password, keyName: "auth.accessToken")
        XCTAssertEqual(token, "legacy-token")
    }

    /// v13 — scrypt(pw, "panda-safe-storage:v13", 32) + AES-256-GCM,
    /// AAD = "panda.secret\0v13\0" ‖ keyName. Random nonce is part of the body.
    func testDecryptV13() throws {
        // Fixed vector (random nonce): encrypt("sk-test-access-token-12345")
        // with pw="test-keyring-password", keyName="auth.accessToken".
        let encrypted = "v13D8+APKmt/LJdKmSQ9v7ApWe+A3ZYR+tQ6MeBt7ZB9epwwK70Cg2J8L+eER2gVrbR5fokQ81c"
        let token = try PandaTokenProvider.decryptForTesting(
            encryptedValue: encrypted, keyringPassword: password, keyName: "auth.accessToken")
        XCTAssertEqual(token, "sk-test-access-token-12345")
    }

    /// A v13 body bound to a different key name must NOT decrypt — the AAD
    /// binds each row to its key, so cross-row replay is rejected.
    func testDecryptV13RejectsWrongKeyName() {
        let encrypted = "v13D8+APKmt/LJdKmSQ9v7ApWe+A3ZYR+tQ6MeBt7ZB9epwwK70Cg2J8L+eER2gVrbR5fokQ81c"
        XCTAssertThrowsError(try PandaTokenProvider.decryptForTesting(
            encryptedValue: encrypted, keyringPassword: password, keyName: "auth.refreshToken"))
    }

    func testUnknownVersionFails() {
        XCTAssertThrowsError(try PandaTokenProvider.decryptForTesting(
            encryptedValue: "v99AAAA", keyringPassword: password, keyName: "auth.accessToken"))
    }
}
