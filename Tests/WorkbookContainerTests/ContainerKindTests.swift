import Foundation
import XCTest
@testable import WorkbookContainer

/// What a file *is*, before anything tries to parse it as a workbook.
///
/// **Four different conditions were reporting as one.** A census of 2,240 workbooks found
/// four that a ZIP reader refused, and they were called corrupt. Two were password-protected
/// and perfectly intact, one was a plain-text memo with an `.xlsx` extension, and only one
/// was actually damaged. "This workbook is password-protected" and "this file is damaged"
/// ask completely different things of whoever reads the report, and the difference is
/// visible in the first eight bytes.
final class ContainerKindTests: XCTestCase {

    private func bytes(_ values: [UInt8], padTo count: Int = 16) -> Data {
        var data = Data(values)
        while data.count < count { data.append(0x00) }
        return data
    }

    func testAZipIsAWorkbookContainer() {
        // "PK\u{3}\u{4}" — the local file header every .xlsx starts with.
        XCTAssertEqual(ContainerKind(of: bytes([0x50, 0x4B, 0x03, 0x04])), .zip)
    }

    func testAnEmptyArchiveIsStillAZip() {
        // A ZIP with no entries starts at the end-of-central-directory record. It is a
        // workbook that will fail for its own reasons, not a file of unknown type.
        XCTAssertEqual(ContainerKind(of: bytes([0x50, 0x4B, 0x05, 0x06])), .zip)
    }

    func testACompoundFileIsAnEncryptedWorkbook() {
        // The OLE2/CFB signature. An ECMA-376 encrypted .xlsx is a compound file whose
        // streams hold the encrypted package — not a ZIP at all, which is exactly why a
        // ZIP reader reports damage.
        XCTAssertEqual(ContainerKind(of: bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])),
                       .compoundFile)
    }

    func testPlainTextIsNotAWorkbookAtAll() {
        // Observed: a 719-byte memo saved with an .xlsx extension.
        let memo = Data("Hypothesis: Trailers will increase viewer interest".utf8)
        XCTAssertEqual(ContainerKind(of: memo), .unrecognised)
    }

    func testGenuinelyCorruptBytesAreUnrecognised() {
        // Observed: 2.4MB of high-entropy data with no ZIP header anywhere in it.
        XCTAssertEqual(ContainerKind(of: bytes([0x45, 0xE7, 0x1E, 0x8A, 0xF7, 0x9D, 0x7E, 0xBA])),
                       .unrecognised)
    }

    func testAFileTooShortToHaveASignatureIsUnrecognised() {
        // Guarding the prefix read: a two-byte file must not index past its own end.
        XCTAssertEqual(ContainerKind(of: Data([0x50, 0x4B])), .unrecognised)
        XCTAssertEqual(ContainerKind(of: Data()), .unrecognised)
    }

    func testAZipSignatureMustBeAtTheStart() {
        // A ZIP header found later in the file does not make the file a ZIP; it makes it
        // something with a ZIP inside it, which is not a workbook a reader can open.
        XCTAssertEqual(ContainerKind(of: bytes([0x00, 0x00, 0x50, 0x4B, 0x03, 0x04])),
                       .unrecognised)
    }

    /// The kind has to say whether it is worth asking for a password.
    func testOnlyACompoundFileInvitesAPassword() {
        XCTAssertTrue(ContainerKind.compoundFile.mayBeEncrypted)
        XCTAssertFalse(ContainerKind.zip.mayBeEncrypted)
        XCTAssertFalse(ContainerKind.unrecognised.mayBeEncrypted)
    }
}
