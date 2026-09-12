import Foundation
import XCTest
@testable import WorkbookContainer

/// Decrypting an ECMA-376 protected workbook.
///
/// The measure of success is exact: decrypting must reproduce the original package **byte
/// for byte**, because the result is handed straight to a ZIP reader. A nearly-right answer
/// is not a partial success here, it is a corrupt archive.
final class WorkbookDecryptorTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: nil),
                                "fixture \(name) is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    func testTheRightPasswordReproducesTheOriginalExactly() throws {
        let decrypted = try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"),
                                                      password: "swordfish")
        XCTAssertEqual(decrypted, try fixture("plain.xlsx"),
                       "decryption must reproduce the package byte for byte")
    }

    func testTheDecryptedBytesAreAWorkbookAZipReaderWouldAccept() throws {
        let decrypted = try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"),
                                                      password: "swordfish")
        XCTAssertEqual(ContainerKind(of: decrypted), .zip)
    }

    /// A wrong password must be *reported*, not returned as rubbish.
    ///
    /// The format carries a verifier precisely so this is knowable before decrypting
    /// anything, and handing back plausible-looking garbage would be the worse failure.
    func testAWrongPasswordIsRefusedRatherThanProducingRubbish() throws {
        XCTAssertThrowsError(
            try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"),
                                          password: "not the password")
        ) { error in
            guard case WorkbookDecryptionError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
    }

    func testAnEmptyPasswordIsAWrongPasswordNotACrash() throws {
        XCTAssertThrowsError(
            try WorkbookDecryptor.decrypt(try fixture("agile-encrypted.xlsx"), password: "")
        ) { error in
            guard case WorkbookDecryptionError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
    }

    func testAnUnencryptedWorkbookIsRefusedAsNotEncrypted() throws {
        XCTAssertThrowsError(
            try WorkbookDecryptor.decrypt(try fixture("plain.xlsx"), password: "swordfish")
        ) { error in
            guard case WorkbookDecryptionError.notEncrypted = error else {
                return XCTFail("expected notEncrypted, got \(error)")
            }
        }
    }

    /// The cheap question — "would a password even help?" — must not need a password.
    func testWhetherAFileIsEncryptedIsAnswerableWithoutOne() throws {
        XCTAssertTrue(WorkbookDecryptor.isEncrypted(try fixture("agile-encrypted.xlsx")))
        XCTAssertFalse(WorkbookDecryptor.isEncrypted(try fixture("plain.xlsx")))
        XCTAssertFalse(WorkbookDecryptor.isEncrypted(Data("not a workbook".utf8)))
    }

    func testTheDescriptorReadsTheParametersTheFileDeclares() throws {
        let container = try CompoundFile(try fixture("agile-encrypted.xlsx"))
        let descriptor = try AgileEncryption(stream: try container.stream(named: "EncryptionInfo"))
        XCTAssertEqual(descriptor.keyData.cipherAlgorithm, "AES")
        XCTAssertEqual(descriptor.keyData.cipherChaining, "ChainingModeCBC")
        XCTAssertGreaterThan(descriptor.passwordKey.spinCount, 0)
        XCTAssertEqual(descriptor.passwordKey.keyBits % 8, 0)
        XCTAssertFalse(descriptor.passwordKey.saltValue.isEmpty)
    }
}

/// The hashes this accepts, and the one it refuses on purpose.
extension WorkbookDecryptorTests {

    func testTheDescriptorSpellingIsNormalisedRatherThanMatchedLiterally() {
        // Writers disagree about punctuation; the algorithm is the same either way.
        XCTAssertEqual(EncryptionHash(descriptorName: "SHA512"), .sha512)
        XCTAssertEqual(EncryptionHash(descriptorName: "SHA-512"), .sha512)
        XCTAssertEqual(EncryptionHash(descriptorName: "sha512"), .sha512)
        XCTAssertEqual(EncryptionHash(descriptorName: "SHA256"), .sha256)
    }

    /// SHA-1 is supported because real files require it.
    ///
    /// It was dropped once, on the theory that agile encryption implies Excel 2010 and
    /// therefore SHA-512. The two 2012 workbooks that prompted this feature both declare
    /// `SHA1` with 128-bit AES, so that theory broke exactly the case it was built for. The
    /// theory had been checked against a fixture this project generated itself.
    func testSHA1IsSupportedBecauseRealFilesUseIt() {
        XCTAssertEqual(EncryptionHash(descriptorName: "SHA1"), .sha1)
        XCTAssertEqual(EncryptionHash(descriptorName: "SHA-1"), .sha1)
    }
}

/// The parameter combinations real files actually use.
///
/// A fixture set that only contains what the code already handles cannot fail, which is not
/// a theoretical concern here — it is how SHA-1 came to be dropped while every test passed.
extension WorkbookDecryptorTests {

    /// SHA-1 with 128-bit AES, which is what the workbooks this feature exists for declare.
    func testSHA1WithAES128Decrypts() throws {
        let decrypted = try WorkbookDecryptor.decrypt(try fixture("agile-sha1-aes128.xlsx"),
                                                      password: "swordfish")
        XCTAssertEqual(decrypted, try fixture("plain.xlsx"),
                       "SHA-1 with AES-128 must decrypt byte for byte, as SHA-512 does")
    }

    func testTheSHA1FixtureReallyDeclaresSHA1() throws {
        // Guarding the guard: a fixture silently regenerated with different parameters
        // would leave this suite green while testing the same path twice.
        let container = try CompoundFile(try fixture("agile-sha1-aes128.xlsx"))
        let descriptor = try AgileEncryption(stream: try container.stream(named: "EncryptionInfo"))
        XCTAssertEqual(descriptor.keyData.hashAlgorithm, .sha1)
        XCTAssertEqual(descriptor.passwordKey.hashAlgorithm, .sha1)
        XCTAssertEqual(descriptor.keyData.keyBits, 128)
    }

    func testAWrongPasswordIsRefusedForSHA1Too() throws {
        XCTAssertThrowsError(
            try WorkbookDecryptor.decrypt(try fixture("agile-sha1-aes128.xlsx"),
                                          password: "not it")
        ) { error in
            guard case WorkbookDecryptionError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
    }
}
