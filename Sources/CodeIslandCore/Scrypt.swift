import CryptoKit
import Foundation

/// Pure-Swift scrypt (RFC 7914) — macOS exposes no system scrypt and
/// CryptoKit only ships HKDF/PBKDF2, but Panda's secret store derives its
/// AES key with `crypto.scryptSync(password, "saltysalt", 16)`
/// (Node defaults: N=16384, r=8, p=1), so we need the real thing.
public enum Scrypt {
    public enum ScryptError: Error { case invalidParameters }

    /// RFC 7914 scrypt. `N` must be a power of two > 1, `r`/`p` > 0.
    public static func derive(
        password: [UInt8],
        salt: [UInt8],
        N: Int,
        r: Int,
        p: Int,
        dkLen: Int
    ) throws -> [UInt8] {
        guard N > 1, N & (N - 1) == 0, r > 0, p > 0,
              N <= Int.max / (128 * r),
              dkLen > 0 else { throw ScryptError.invalidParameters }

        // 1. B = PBKDF2-HMAC-SHA256(P, S, 1, p * 128 * r), viewed as p blocks.
        let blockBytes = 128 * r
        var B = try pbkdf2Sha256(password: password, salt: salt, iterations: 1, dkLen: p * blockBytes)

        // 2. ROMix each block.
        for i in 0..<p {
            let start = i * blockBytes
            let mixed = romix(r: r, block: Array(B[start..<start + blockBytes]), N: N)
            B.replaceSubrange(start..<start + blockBytes, with: mixed)
        }

        // 3. DK = PBKDF2-HMAC-SHA256(P, B, 1, dkLen).
        return try pbkdf2Sha256(password: password, salt: B, iterations: 1, dkLen: dkLen)
    }

    // MARK: - ROMix

    private static func romix(r: Int, block: [UInt8], N: Int) -> [UInt8] {
        let wordsPerBlock = 32 * r // 128*r bytes as uint32 words
        var x = words(block)
        var v = [[UInt32]](repeating: [UInt32](repeating: 0, count: wordsPerBlock), count: N)

        for i in 0..<N {
            v[i] = x
            blockMix(&x, r: r)
        }
        let mask = N - 1
        for _ in 0..<N {
            // Integerify: interpret B[2r-1] (the LAST chunk) as LE integer, mod N.
            let j = Int(x[(2 * r - 1) * 16]) & mask
            var b = v[j]
            for w in 0..<wordsPerBlock { b[w] ^= x[w] }
            x = words(bytes(b))
            blockMix(&x, r: r)
        }
        return bytes(x)
    }

    /// scryptBlockMix over 128*r bytes (2r chunks of 64 bytes = 16 words each).
    private static func blockMix(_ x: inout [UInt32], r: Int) {
        var y = [UInt32](repeating: 0, count: x.count)
        // RFC 7914: X starts as the LAST chunk B[2r-1].
        var xLocal = Array(x[(2 * r - 1) * 16..<(2 * r) * 16])
        var tmp = [UInt32](repeating: 0, count: 16)

        for i in 0..<(2 * r) {
            let srcOffset = i * 16
            for w in 0..<16 { tmp[w] = xLocal[w] ^ x[srcOffset + w] }
            salsa20_8(&tmp)
            xLocal = tmp
            let dstWord = (i & 1 == 0 ? (i >> 1) : (r + (i - 1) / 2)) * 16
            for w in 0..<16 { y[dstWord + w] = xLocal[w] }
        }
        x = y
    }

    /// Salsa20/8 core (RFC 7914 §8), in-place over 64 bytes (16 LE words).
    private static func salsa20_8(_ b: inout [UInt32]) {
        func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
        var x = b
        // Salsa20/8 = 8 rounds = 4 double-rounds (column + row each).
        for _ in 0..<4 {
            // Column rounds
            x[4]  ^= rotl(x[0]  &+ x[12], 7);  x[8]  ^= rotl(x[4]  &+ x[0], 9)
            x[12] ^= rotl(x[8]  &+ x[4], 13);  x[0]  ^= rotl(x[12] &+ x[8], 18)
            x[9]  ^= rotl(x[5]  &+ x[1], 7);   x[13] ^= rotl(x[9]  &+ x[5], 9)
            x[1]  ^= rotl(x[13] &+ x[9], 13);  x[5]  ^= rotl(x[1]  &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7);   x[2]  ^= rotl(x[14] &+ x[10], 9)
            x[6]  ^= rotl(x[2]  &+ x[14], 13); x[10] ^= rotl(x[6]  &+ x[2], 18)
            x[3]  ^= rotl(x[15] &+ x[11], 7);  x[7]  ^= rotl(x[3]  &+ x[15], 9)
            x[11] ^= rotl(x[7]  &+ x[3], 13);  x[15] ^= rotl(x[11] &+ x[7], 18)
            // Row rounds
            x[1]  ^= rotl(x[0]  &+ x[3], 7);   x[2]  ^= rotl(x[1]  &+ x[0], 9)
            x[3]  ^= rotl(x[2]  &+ x[1], 13);  x[0]  ^= rotl(x[3]  &+ x[2], 18)
            x[6]  ^= rotl(x[5]  &+ x[4], 7);   x[7]  ^= rotl(x[6]  &+ x[5], 9)
            x[4]  ^= rotl(x[7]  &+ x[6], 13);  x[5]  ^= rotl(x[4]  &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7);   x[8]  ^= rotl(x[11] &+ x[10], 9)
            x[9]  ^= rotl(x[8]  &+ x[11], 13); x[10] ^= rotl(x[9]  &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7);  x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
        for i in 0..<16 { b[i] = b[i] &+ x[i] }
    }

    // MARK: - Primitives

    private static func words(_ bytes: [UInt8]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: bytes.count / 4)
        for i in 0..<out.count {
            let o = i * 4
            out[i] = UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8)
                | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        return out
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: words.count * 4)
        for (i, w) in words.enumerated() {
            let o = i * 4
            out[o] = UInt8(w & 0xFF)
            out[o + 1] = UInt8((w >> 8) & 0xFF)
            out[o + 2] = UInt8((w >> 16) & 0xFF)
            out[o + 3] = UInt8((w >> 24) & 0xFF)
        }
        return out
    }

    /// PBKDF2-HMAC-SHA256 via CryptoKit HMAC.
    static func pbkdf2Sha256(password: [UInt8], salt: [UInt8], iterations: Int, dkLen: Int) throws -> [UInt8] {
        precondition(iterations >= 1)
        let hLen = 32
        let blocks = (dkLen + hLen - 1) / hLen
        var out = [UInt8]()
        out.reserveCapacity(dkLen)
        for blockIndex in 1...blocks {
            var saltBlock = salt
            let bi = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: bi) { saltBlock.append(contentsOf: $0) }

            // HMAC(password, salt || INT_32_BE(i)) — password is the KEY.
            let key = SymmetricKey(data: password)
            var u = Array(HMAC<SHA256>.authenticationCode(for: saltBlock, using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            out.append(contentsOf: t)
        }
        return Array(out.prefix(dkLen))
    }
}
