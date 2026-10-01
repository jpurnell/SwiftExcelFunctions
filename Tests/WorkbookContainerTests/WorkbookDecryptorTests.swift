import Foundation
import Foundation
import Testing
@testable import WorkbookContainer

/// Decrypting an ECMA-376 protected workbook.
///
/// The measure of success is exact: decrypting must reproduce the original package **byte
/// for byte**, because the result is handed straight to a ZIP reader. A nearly-right answer
/// is not a partial success here, it is a corrupt archive.
@Suite struct WorkbookDecryptorTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: nil), "fixture \(name) is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    @Test func theRightPasswordReproducesTheOriginalExactly() throws {
        let decrypted = try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"),
                                                      password: "swordfish")
        #expect(try decrypted == fixture("plain.xlsx"), "decryption must reproduce the package byte for byte")
    }

    @Test func theDecryptedBytesAreAWorkbookAZipReaderWouldAccept() throws {
        let decrypted = try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"),
                                                      password: "swordfish")
        #expect(ContainerKind(of: decrypted) == .zip)
    }

    /// A wrong password must be *reported*, not returned as rubbish.
    ///
    /// The format carries a verifier precisely so this is knowable before decrypting
    /// anything, and handing back plausible-looking garbage would be the worse failure.
    @Test func aWrongPasswordIsRefusedRatherThanProducingRubbish() throws {
        if let error = #expect(throws: (any Error).self, performing: { try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"),
                                          password: "not the password") }) {
            guard case WorkbookDecryptionError.wrongPassword = error else {
                Issue.record("expected wrongPassword, got \(error)"); return
            }
        }
    }

    @Test func anEmptyPasswordIsAWrongPasswordNotACrash() throws {
        if let error = #expect(throws: (any Error).self, performing: { try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"), password: "") }) {
            guard case WorkbookDecryptionError.wrongPassword = error else {
                Issue.record("expected wrongPassword, got \(error)"); return
            }
        }
    }

    @Test func anUnencryptedWorkbookIsRefusedAsNotEncrypted() throws {
        if let error = #expect(throws: (any Error).self, performing: { try WorkbookDecryptor.decrypt(try fixture("plain.xlsx"), password: "swordfish") }) {
            guard case WorkbookDecryptionError.notEncrypted = error else {
                Issue.record("expected notEncrypted, got \(error)"); return
            }
        }
    }

    /// The cheap question — "would a password even help?" — must not need a password.
    @Test func whetherAFileIsEncryptedIsAnswerableWithoutOne() throws {
        #expect(WorkbookDecryptor.isEncrypted(try fixture("agile-encrypted.xlsx")))
        #expect(!WorkbookDecryptor.isEncrypted(try fixture("plain.xlsx")))
        #expect(!WorkbookDecryptor.isEncrypted(Data("not a workbook".utf8)))
    }

    @Test func theDescriptorReadsTheParametersTheFileDeclares() throws {
        let container = try CompoundFile(try fixture("agile-encrypted.xlsx"))
        let descriptor = try AgileEncryption(stream: try container.stream(named: "EncryptionInfo"))
        #expect(descriptor.keyData.cipherAlgorithm == "AES")
        #expect(descriptor.keyData.cipherChaining == "ChainingModeCBC")
        #expect(descriptor.passwordKey.spinCount > 0)
        #expect((descriptor.passwordKey.keyBits % 8) == 0)
        #expect(!descriptor.passwordKey.saltValue.isEmpty)
    }
}

/// The hashes this accepts, and the one it refuses on purpose.
extension WorkbookDecryptorTests {

    @Test func theDescriptorSpellingIsNormalisedRatherThanMatchedLiterally() {
        // Writers disagree about punctuation; the algorithm is the same either way.
        #expect(EncryptionHash(descriptorName: "SHA512") == .sha512)
        #expect(EncryptionHash(descriptorName: "SHA-512") == .sha512)
        #expect(EncryptionHash(descriptorName: "sha512") == .sha512)
        #expect(EncryptionHash(descriptorName: "SHA256") == .sha256)
    }

    /// SHA-1 is supported because real files require it.
    ///
    /// It was dropped once, on the theory that agile encryption implies Excel 2010 and
    /// therefore SHA-512. The two 2012 workbooks that prompted this feature both declare
    /// `SHA1` with 128-bit AES, so that theory broke exactly the case it was built for. The
    /// theory had been checked against a fixture this project generated itself.
    @Test func sha1IsSupportedBecauseRealFilesUseIt() {
        #expect(EncryptionHash(descriptorName: "SHA1") == .sha1)
        #expect(EncryptionHash(descriptorName: "SHA-1") == .sha1)
    }
}

/// The parameter combinations real files actually use.
///
/// A fixture set that only contains what the code already handles cannot fail, which is not
/// a theoretical concern here — it is how SHA-1 came to be dropped while every test passed.
extension WorkbookDecryptorTests {

    /// SHA-1 with 128-bit AES, which is what the workbooks this feature exists for declare.
    @Test func sha1WithAES128Decrypts() throws {
        let decrypted = try WorkbookDecryptor.decrypt(try fixture("agile-sha1-aes128.xlsx"),
                                                      password: "swordfish")
        #expect(try decrypted == fixture("plain.xlsx"), "SHA-1 with AES-128 must decrypt byte for byte, as SHA-512 does")
    }

    @Test func theSHA1FixtureReallyDeclaresSHA1() throws {
        // Guarding the guard: a fixture silently regenerated with different parameters
        // would leave this suite green while testing the same path twice.
        let container = try CompoundFile(try fixture("agile-sha1-aes128.xlsx"))
        let descriptor = try AgileEncryption(stream: try container.stream(named: "EncryptionInfo"))
        #expect(descriptor.keyData.hashAlgorithm == .sha1)
        #expect(descriptor.passwordKey.hashAlgorithm == .sha1)
        #expect(descriptor.keyData.keyBits == 128)
    }

    @Test func aWrongPasswordIsRefusedForSHA1Too() throws {
        if let error = #expect(throws: (any Error).self, performing: { try WorkbookDecryptor.decrypt(try fixture("agile-sha1-aes128.xlsx"),
                                          password: "not it") }) {
            guard case WorkbookDecryptionError.wrongPassword = error else {
                Issue.record("expected wrongPassword, got \(error)"); return
            }
        }
    }
}
