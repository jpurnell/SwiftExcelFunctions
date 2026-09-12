import Crypto
import Foundation

/// The hash a file says it was protected with.
///
/// Excel writes SHA-512 and has for years, but the descriptor is free to name another and a
/// reader that assumed one would silently derive the wrong key — which looks exactly like a
/// wrong password, and would send someone hunting for a passphrase that was already right.
///
/// **SHA-1 is here because real files need it**, and that was established the hard way. It
/// was dropped first, on the reasoning that agile encryption dates from Excel 2010 and Excel
/// writes SHA-512 — reasoning checked against a fixture this project had generated itself,
/// which naturally used SHA-512. The two workbooks that prompted the whole feature are from
/// 2012 and both declare `SHA1` with 128-bit AES, so dropping it broke precisely the case it
/// was written for. A fixture agreeing with the code about something neither had checked is
/// the recurring way this project gets things wrong.
///
/// Reading SHA-1 here is not a security choice. Nothing signs or protects anything with it;
/// it derives a key for a file somebody else encrypted years ago, and the alternative is
/// refusing to open their file. Weak-hash warnings are about what new work relies on.
enum EncryptionHash: String, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha384 = "SHA384"
    case sha512 = "SHA512"

    /// Reads the algorithm from the descriptor's spelling of it.
    ///
    /// Punctuation varies between writers — `SHA-512` and `SHA512` both appear — so it is
    /// normalised rather than matched literally.
    init?(descriptorName: String) {
        let normalised = descriptorName.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let match = EncryptionHash(rawValue: normalised) else { return nil }
        self = match
    }

    /// The digest of some bytes.
    func hash(_ data: Data) -> Data {
        switch self {
        // Justification: the file names SHA-1; reading it is not a security choice.
        case .sha1: return Data(Insecure.SHA1.hash(data: data))
        case .sha256: return Data(SHA256.hash(data: data))
        case .sha384: return Data(SHA384.hash(data: data))
        case .sha512: return Data(SHA512.hash(data: data))
        }
    }
}

/// The parameters an agile-encrypted workbook declares about itself.
///
/// **Nothing here is assumed.** Salt, spin count, key length, cipher and hash all come out of
/// the file, because they are all free to vary and a file encrypted by something other than
/// the current Excel may vary them. The one thing the reader insists on is AES in CBC mode,
/// which is refused explicitly rather than mis-decrypted.
struct AgileEncryption: Sendable {

    /// How the package itself is encrypted.
    struct KeyData: Sendable {
        let saltSize: Int
        let blockSize: Int
        let keyBits: Int
        let hashSize: Int
        let cipherAlgorithm: String
        let cipherChaining: String
        let hashAlgorithm: EncryptionHash
        let saltValue: Data
    }

    /// How the key to the package is itself encrypted, under a password.
    struct PasswordKeyEncryptor: Sendable {
        let spinCount: Int
        let saltSize: Int
        let blockSize: Int
        let keyBits: Int
        let hashSize: Int
        let cipherAlgorithm: String
        let cipherChaining: String
        let hashAlgorithm: EncryptionHash
        let saltValue: Data
        let encryptedVerifierHashInput: Data
        let encryptedVerifierHashValue: Data
        let encryptedKeyValue: Data
    }

    let keyData: KeyData
    let passwordKey: PasswordKeyEncryptor

    /// Reads the descriptor out of an `EncryptionInfo` stream.
    ///
    /// The stream begins with a four-byte version. Major 4, minor 4 is agile encryption and
    /// the rest is a UTF-8 XML descriptor after an eight-byte preamble. Other versions are
    /// older schemes with a binary layout, and are refused by name rather than guessed at.
    ///
    /// - Parameter stream: The whole `EncryptionInfo` stream.
    init(stream: Data) throws {
        guard stream.count > 8 else {
            throw WorkbookDecryptionError.malformedDescriptor("EncryptionInfo is too short")
        }
        let bytes = [UInt8](stream)
        let major = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let minor = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        guard major == 4, minor == 4 else {
            throw WorkbookDecryptionError.unsupportedScheme(
                "encryption version \(major).\(minor); only 4.4 (agile) is implemented")
        }

        let parsed = try AgileDescriptorParser.attributes(inXML: stream.dropFirst(8))

        func data(_ dictionary: [String: String], _ key: String) throws -> Data {
            guard let encoded = dictionary[key], let decoded = Data(base64Encoded: encoded) else {
                throw WorkbookDecryptionError.malformedDescriptor("\(key) is missing or not base64")
            }
            return decoded
        }
        func number(_ dictionary: [String: String], _ key: String) throws -> Int {
            guard let raw = dictionary[key], let value = Int(raw) else {
                throw WorkbookDecryptionError.malformedDescriptor("\(key) is missing or not a number")
            }
            return value
        }
        func hash(_ dictionary: [String: String]) throws -> EncryptionHash {
            let name = dictionary["hashAlgorithm"] ?? "?"
            guard let algorithm = EncryptionHash(descriptorName: name) else {
                throw WorkbookDecryptionError.unsupportedScheme("hash \(name)")
            }
            return algorithm
        }
        func requireAESInCBC(_ dictionary: [String: String]) throws {
            let cipher = dictionary["cipherAlgorithm"] ?? "?"
            let chaining = dictionary["cipherChaining"] ?? "?"
            guard cipher == "AES", chaining == "ChainingModeCBC" else {
                throw WorkbookDecryptionError.unsupportedScheme("\(cipher) in \(chaining)")
            }
        }

        try requireAESInCBC(parsed.keyData)
        try requireAESInCBC(parsed.passwordKey)

        keyData = KeyData(
            saltSize: try number(parsed.keyData, "saltSize"),
            blockSize: try number(parsed.keyData, "blockSize"),
            keyBits: try number(parsed.keyData, "keyBits"),
            hashSize: try number(parsed.keyData, "hashSize"),
            cipherAlgorithm: parsed.keyData["cipherAlgorithm"] ?? "",
            cipherChaining: parsed.keyData["cipherChaining"] ?? "",
            hashAlgorithm: try hash(parsed.keyData),
            saltValue: try data(parsed.keyData, "saltValue"))

        passwordKey = PasswordKeyEncryptor(
            spinCount: try number(parsed.passwordKey, "spinCount"),
            saltSize: try number(parsed.passwordKey, "saltSize"),
            blockSize: try number(parsed.passwordKey, "blockSize"),
            keyBits: try number(parsed.passwordKey, "keyBits"),
            hashSize: try number(parsed.passwordKey, "hashSize"),
            cipherAlgorithm: parsed.passwordKey["cipherAlgorithm"] ?? "",
            cipherChaining: parsed.passwordKey["cipherChaining"] ?? "",
            hashAlgorithm: try hash(parsed.passwordKey),
            saltValue: try data(parsed.passwordKey, "saltValue"),
            encryptedVerifierHashInput: try data(parsed.passwordKey, "encryptedVerifierHashInput"),
            encryptedVerifierHashValue: try data(parsed.passwordKey, "encryptedVerifierHashValue"),
            encryptedKeyValue: try data(parsed.passwordKey, "encryptedKeyValue"))
    }
}

/// Pulls the two attribute sets the descriptor carries out of its XML.
///
/// Element names are matched on their local part, because the descriptor is namespaced and
/// writers disagree about the prefix — `p:encryptedKey` and `encryptedKey` both occur.
private final class AgileDescriptorParser: NSObject, XMLParserDelegate {

    struct Attributes {
        var keyData: [String: String] = [:]
        var passwordKey: [String: String] = [:]
    }

    private var found = Attributes()

    static func attributes(inXML xml: Data) throws -> Attributes {
        let delegate = AgileDescriptorParser()
        let parser = XMLParser(data: Data(xml))
        parser.delegate = delegate
        guard parser.parse() else {
            throw WorkbookDecryptionError.malformedDescriptor(
                "EncryptionInfo XML did not parse: \(parser.parserError?.localizedDescription ?? "?")")
        }
        guard !delegate.found.keyData.isEmpty else {
            throw WorkbookDecryptionError.malformedDescriptor("no <keyData> element")
        }
        guard !delegate.found.passwordKey.isEmpty else {
            // A file encrypted only to a certificate has no password encryptor, and no
            // password will ever open it. Saying so beats reporting a wrong password.
            throw WorkbookDecryptionError.unsupportedScheme(
                "no password key encryptor — the file may be protected by certificate")
        }
        return delegate.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch local {
        case "keyData": found.keyData = attributes
        case "encryptedKey": found.passwordKey = attributes
        default: break
        }
    }
}
