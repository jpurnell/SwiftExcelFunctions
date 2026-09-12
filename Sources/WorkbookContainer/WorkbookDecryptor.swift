import Crypto
import Foundation
#if canImport(os)
import os
#endif
import _CryptoExtras

/// Why an encrypted workbook could not be opened.
public enum WorkbookDecryptionError: Error, CustomStringConvertible, Sendable, Equatable {

    /// The password did not match the verifier the file carries.
    case wrongPassword

    /// The file is not encrypted, so there is nothing to decrypt.
    case notEncrypted

    /// The file is encrypted by a scheme this does not implement.
    case unsupportedScheme(String)

    /// The descriptor is present but does not say what it must.
    case malformedDescriptor(String)

    /// The container holds the descriptor but not the package, or the reverse.
    case missingStream(String)

    /// A one-line account of what went wrong, for a report a person will read.
    ///
    /// Said plainly and without jargon: a decryption failure usually reaches someone
    /// holding a file rather than a debugger, and "needs a password" has to be
    /// distinguishable from "damaged" at a glance.
    public var description: String {
        switch self {
        case .wrongPassword:
            return "the password does not open this workbook"
        case .notEncrypted:
            return "this workbook is not encrypted"
        case .unsupportedScheme(let what):
            return "unsupported encryption: \(what)"
        case .malformedDescriptor(let why):
            return "malformed encryption descriptor: \(why)"
        case .missingStream(let name):
            return "an encrypted workbook without a \(name) stream"
        }
    }
}

/// Opens a password-protected `.xlsx`.
///
/// **A protected workbook is not a damaged one, and the difference is worth code.** ECMA-376
/// encryption puts the whole package inside an OLE2 compound file, so a ZIP reader sees a
/// broken archive and says so. A census of 2,240 real workbooks reported two intact,
/// password-protected files as corrupt on exactly that basis. Given the password, both open.
///
/// ## What is implemented
///
/// Agile encryption — version 4.4, what Excel has written since 2010: AES in CBC mode, with
/// the key derived from the password by an iterated hash. The older standard (4.2) and
/// legacy RC4 schemes are refused by name rather than guessed at, because a wrong guess here
/// produces plausible bytes rather than an error.
///
/// ```swift
/// let locked = try Data(contentsOf: URL(fileURLWithPath: "/tmp/locked.xlsx"))
/// if WorkbookDecryptor.isEncrypted(locked) {
///     let opened = try WorkbookDecryptor.decrypt(locked, password: "swordfish")
///     // `opened` is an ordinary .xlsx, ready for any ZIP-based reader.
///     print(opened.count)
/// }
/// ```
///
/// ## On the password
///
/// It is verified before the package is touched. The format stores a verifier for exactly
/// this purpose, so a wrong password is reported as one instead of yielding rubbish that
/// fails later as a corrupt archive — which would send someone looking for a damaged file
/// rather than a better password.
public enum WorkbookDecryptor {

    /// The block keys the specification fixes for each derived key. They are constants of
    /// the format, not choices, and are written here exactly as it defines them.
    private enum BlockKey {
        static let verifierHashInput: [UInt8] = [0xFE, 0xA7, 0xD2, 0x76, 0x3B, 0x4B, 0x9E, 0x79]
        static let verifierHashValue: [UInt8] = [0xD7, 0xAA, 0x0F, 0x6D, 0x30, 0x61, 0x34, 0x4E]
        static let keyValue: [UInt8] = [0x14, 0x6E, 0x0B, 0xE7, 0xAB, 0xAC, 0xD0, 0xD6]
    }

    /// The package is encrypted in independently-keyed segments of this size.
    private static let segmentSize = 4096

    /// Whether a password would help — answerable without one.
    ///
    /// - Parameter data: The file's bytes.
    /// - Returns: `true` if this is a compound file carrying an `EncryptionInfo` stream.
    public static func isEncrypted(_ data: Data) -> Bool {
        guard ContainerKind(of: data) == .compoundFile else { return false }
        do {
            return try CompoundFile(data).streamNames.contains("EncryptionInfo")
        } catch {
            // Reaching here means the file carries the compound-file signature and then
            // fails to parse as one, which is a damaged container rather than an ordinary
            // "no". The answer is still no, but it is worth saying why.
            #if canImport(os)
            Logger(subsystem: "WorkbookContainer", category: "encryption")
                .error("compound file signature but unreadable structure: \(String(describing: error), privacy: .public)")
            #endif
            return false
        }
    }

    /// Decrypts a password-protected workbook.
    ///
    /// - Parameters:
    ///   - data: The encrypted file, whole.
    ///   - password: The password that opens it.
    /// - Returns: The `.xlsx` package, byte for byte as it was before encryption.
    /// - Throws: ``WorkbookDecryptionError/wrongPassword`` if the password does not verify,
    ///   or ``WorkbookDecryptionError/unsupportedScheme(_:)`` for a scheme not implemented.
    public static func decrypt(_ data: Data, password: String) throws -> Data {
        guard ContainerKind(of: data) == .compoundFile else {
            throw WorkbookDecryptionError.notEncrypted
        }
        let container = try CompoundFile(data)

        let info: Data
        do {
            info = try container.stream(named: "EncryptionInfo")
        } catch {
            throw WorkbookDecryptionError.missingStream("EncryptionInfo")
        }
        let package: Data
        do {
            package = try container.stream(named: "EncryptedPackage")
        } catch {
            throw WorkbookDecryptionError.missingStream("EncryptedPackage")
        }

        let descriptor = try AgileEncryption(stream: info)
        let secret = try secretKey(descriptor: descriptor, password: password)
        return try decryptPackage(package, with: secret, keyData: descriptor.keyData)
    }

    // MARK: - Keys

    /// Derives the key that actually opens the package, verifying the password on the way.
    private static func secretKey(descriptor: AgileEncryption, password: String) throws -> Data {
        let key = descriptor.passwordKey
        let algorithm = key.hashAlgorithm

        // H₀ is the salt followed by the password as UTF-16LE, then the hash is spun
        // `spinCount` times with the iteration number prefixed. The spinning is the cost
        // that makes guessing expensive, and it is the file that chooses how much.
        var running = algorithm.hash(key.saltValue + Data(Array(password.utf16).flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        }))
        for iteration in 0..<key.spinCount {
            running = algorithm.hash(littleEndian(UInt32(truncatingIfNeeded: iteration)) + running)
        }

        let keyLength = key.keyBits / 8
        func derived(_ blockKey: [UInt8]) -> Data {
            Data(algorithm.hash(running + Data(blockKey)).prefix(keyLength))
        }

        // Verify before decrypting anything. The file carries a verifier for this, and
        // using it is the difference between "wrong password" and a corrupt archive later.
        let input = try aesCBCDecrypt(key.encryptedVerifierHashInput,
                                      key: derived(BlockKey.verifierHashInput),
                                      iv: key.saltValue)
        let expected = try aesCBCDecrypt(key.encryptedVerifierHashValue,
                                         key: derived(BlockKey.verifierHashValue),
                                         iv: key.saltValue)
        let actual = algorithm.hash(input)
        guard actual.prefix(key.hashSize) == expected.prefix(key.hashSize) else {
            throw WorkbookDecryptionError.wrongPassword
        }

        let secret = try aesCBCDecrypt(key.encryptedKeyValue,
                                       key: derived(BlockKey.keyValue),
                                       iv: key.saltValue)
        return Data(secret.prefix(descriptor.keyData.keyBits / 8))
    }

    // MARK: - The package

    /// Decrypts the package, segment by independently-keyed segment.
    private static func decryptPackage(_ package: Data, with secret: Data,
                                       keyData: AgileEncryption.KeyData) throws -> Data {
        guard package.count > 8 else {
            throw WorkbookDecryptionError.malformedDescriptor("EncryptedPackage is too short")
        }
        let bytes = [UInt8](package)
        // The stream opens with the plaintext's length, which is what trims the final
        // block's padding at the end — the ciphertext is always a whole number of blocks.
        var declared = UInt64(0)
        for index in (0..<8).reversed() { declared = (declared << 8) | UInt64(bytes[index]) }
        let ciphertext = package.dropFirst(8)

        var plaintext = Data()
        plaintext.reserveCapacity(Int(declared))
        var segment = 0
        var offset = ciphertext.startIndex
        while offset < ciphertext.endIndex {
            let end = ciphertext.index(offset, offsetBy: segmentSize,
                                       limitedBy: ciphertext.endIndex) ?? ciphertext.endIndex
            // Every segment gets its own IV, derived from the segment number, so the
            // segments are independent and a damaged one cannot cascade.
            let iv = keyData.hashAlgorithm
                .hash(keyData.saltValue + littleEndian(UInt32(truncatingIfNeeded: segment)))
                .prefix(keyData.blockSize)
            plaintext += try aesCBCDecrypt(Data(ciphertext[offset..<end]),
                                           key: secret, iv: Data(iv))
            offset = end
            segment += 1
        }

        guard plaintext.count >= Int(declared) else {
            throw WorkbookDecryptionError.malformedDescriptor(
                "decrypted \(plaintext.count) bytes but the package declares \(declared)")
        }
        return Data(plaintext.prefix(Int(declared)))
    }

    /// A 32-bit value as the four little-endian bytes the format prefixes counters with.
    ///
    /// Written out rather than reinterpreted through `withUnsafeBytes`: the bytes are the
    /// whole point here, the order is fixed by the file format rather than by the host, and
    /// a value type's memory has no business escaping a pointer block to be read as bytes.
    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF),
              UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF),
              UInt8((value >> 24) & 0xFF)])
    }

    /// AES-CBC with no padding — the format pads to the block size itself and the length
    /// that trims it is carried separately, so asking the cipher to unpad would corrupt it.
    private static func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let initialisation = try AES._CBC.IV(ivBytes: iv.prefix(16))
        return try AES._CBC.decrypt(ciphertext,
                                    using: SymmetricKey(data: key),
                                    iv: initialisation,
                                    noPadding: true)
    }
}
