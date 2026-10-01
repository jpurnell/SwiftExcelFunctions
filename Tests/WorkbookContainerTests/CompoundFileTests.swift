import Foundation
import Foundation
import Testing
@testable import WorkbookContainer

/// Reading named streams out of an OLE2 compound file.
///
/// An encrypted `.xlsx` is a compound file holding two streams: `EncryptionInfo`, which
/// describes how it was encrypted, and `EncryptedPackage`, which is the workbook. Getting at
/// either means walking the container's own allocation tables, so this is the first thing
/// decryption needs and the first thing worth testing on its own.
@Suite struct CompoundFileTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)",
                                                  withExtension: nil), "fixture \(name) is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    @Test func aCompoundFileExposesTheTwoStreamsEncryptionNeeds() throws {
        let file = try CompoundFile(try fixture("agile-encrypted.xlsx"))
        #expect(file.streamNames.contains("EncryptionInfo"))
        #expect(file.streamNames.contains("EncryptedPackage"))
    }

    /// `EncryptionInfo` is small, so it lives in the mini stream rather than the FAT —
    /// a genuinely separate code path, and the one a naive reader gets wrong.
    @Test func theSmallStreamReadsThroughTheMiniFAT() throws {
        let file = try CompoundFile(try fixture("agile-encrypted.xlsx"))
        let info = try file.stream(named: "EncryptionInfo")
        #expect(info.count < 4096, "this stream should be below the mini-stream cutoff")
        // Version 4.4 marks agile encryption, and the descriptor that follows is XML.
        #expect([UInt8](info.prefix(4)) == [0x04, 0x00, 0x04, 0x00])
        #expect(String(decoding: info.dropFirst(8), as: UTF8.self).contains("<encryption"))
    }

    /// `EncryptedPackage` is large, so it reads through the ordinary FAT chain.
    @Test func theLargeStreamReadsThroughTheFAT() throws {
        let file = try CompoundFile(try fixture("agile-encrypted.xlsx"))
        let package = try file.stream(named: "EncryptedPackage")
        #expect(package.count > 4096)
        // The first eight bytes are the plaintext length, which must be plausible.
        let declared = package.prefix(8).reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(declared > 0)
        #expect(declared < UInt64(package.count))
    }

    @Test func aMissingStreamIsAnErrorRatherThanEmptyData() throws {
        let file = try CompoundFile(try fixture("agile-encrypted.xlsx"))
        if let error = #expect(throws: (any Error).self, performing: { try file.stream(named: "NoSuchStream") }) {
            guard case CompoundFileError.noSuchStream(let name) = error else {
                Issue.record("expected noSuchStream, got \(error)"); return
            }
            #expect(name == "NoSuchStream")
        }
    }

    @Test func aFileThatIsNotACompoundFileIsRefused() throws {
        // The plain workbook is a ZIP, and must not be read as a container.
        if let error = #expect(throws: (any Error).self, performing: { try CompoundFile(try fixture("plain.xlsx")) }) {
            guard case CompoundFileError.notACompoundFile = error else {
                Issue.record("expected notACompoundFile, got \(error)"); return
            }
        }
    }

    @Test func truncatedBytesAreRefusedRatherThanIndexedInto() {
        // Header claims to be a compound file but there is nothing behind it.
        var truncated = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        truncated.append(contentsOf: [UInt8](repeating: 0, count: 16))
        #expect(throws: (any Error).self) { try CompoundFile(truncated) }
    }
}
