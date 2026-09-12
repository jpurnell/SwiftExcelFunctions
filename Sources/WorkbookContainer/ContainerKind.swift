import Foundation

/// What a file is, judged by its first bytes rather than its extension.
///
/// **An extension is a claim; a signature is evidence.** A census of 2,240 real workbooks
/// found four that a ZIP reader refused, and reported all four identically as damaged. They
/// were four different things: two were password-protected and completely intact, one was a
/// plain-text memo that someone had saved as `.xlsx`, and exactly one was actually corrupt.
///
/// Those distinctions are not cosmetic. "This workbook needs a password", "this is not a
/// spreadsheet" and "this file is damaged" ask three different things of whoever reads the
/// report, and only the last is a defect worth investigating. Telling them apart costs eight
/// bytes.
public enum ContainerKind: String, Sendable, CaseIterable {

    /// A ZIP archive — what every unencrypted `.xlsx` is.
    case zip

    /// An OLE2 compound file. For an `.xlsx` this means ECMA-376 encryption: the real
    /// package is a stream *inside* this container, which is why a ZIP reader sees damage.
    case compoundFile

    /// Neither. A text file with the wrong extension, or genuinely corrupt bytes.
    case unrecognised

    /// Whether a password could plausibly open this, so a caller knows when to ask for one.
    public var mayBeEncrypted: Bool { self == .compoundFile }

    /// Classifies a file by its leading signature.
    ///
    /// The signature must be at offset zero. A ZIP header found further in does not make
    /// the file a workbook — it makes it something with an archive embedded in it, which no
    /// reader here can open.
    ///
    /// - Parameter data: The file's bytes. Only the first eight are examined.
    public init(of data: Data) {
        // Guarded rather than assumed: a two-byte file must not index past its own end.
        guard data.count >= 4 else { self = .unrecognised; return }
        let head = [UInt8](data.prefix(8))

        // "PK" then a record type. 03 04 is a local file header and 05 06 an empty
        // archive's end-of-central-directory; both are ZIPs a reader should be given.
        if head[0] == 0x50, head[1] == 0x4B,
           (head[2] == 0x03 && head[3] == 0x04) || (head[2] == 0x05 && head[3] == 0x06) {
            self = .zip
            return
        }

        if head.count >= 8, Array(head[0..<8]) == ContainerKind.compoundFileSignature {
            self = .compoundFile
            return
        }

        self = .unrecognised
    }

    /// The OLE2/CFB header signature, `D0 CF 11 E0 A1 B1 1A E1`.
    private static let compoundFileSignature: [UInt8] =
        [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
}
