import Foundation

/// Why a compound file could not be read.
public enum CompoundFileError: Error, CustomStringConvertible, Sendable, Equatable {

    /// The leading signature is not `D0CF11E0A1B11AE1`.
    case notACompoundFile

    /// The file ends before a structure it declares.
    case truncated(String)

    /// A header field is outside the range the format allows.
    case malformed(String)

    /// The container is well-formed but holds no stream of that name.
    case noSuchStream(String)

    /// A one-line account of what went wrong, for a report a person will read.
    ///
    /// Said plainly and without jargon: a container failure usually reaches someone
    /// holding a file rather than a debugger, and "needs a password" has to be
    /// distinguishable from "damaged" at a glance.
    public var description: String {
        switch self {
        case .notACompoundFile:
            return "not an OLE2 compound file"
        case .truncated(let what):
            return "file ends before \(what)"
        case .malformed(let why):
            return "malformed compound file: \(why)"
        case .noSuchStream(let name):
            return "no stream named \(name)"
        }
    }
}

/// An OLE2 compound file, read far enough to pull named streams out of it.
///
/// **This is the container an encrypted `.xlsx` actually is.** ECMA-376 encryption does not
/// encrypt a ZIP in place; it puts the whole package inside a compound file as a stream
/// called `EncryptedPackage`, alongside an `EncryptionInfo` stream describing how. A ZIP
/// reader handed one of these sees `D0CF11E0…` where `PK\u{3}\u{4}` should be and reports a
/// damaged archive, which is how two intact workbooks came to be recorded as corrupt.
///
/// Only reading is implemented, and only what decryption needs: the FAT, the mini-FAT, and
/// the directory. Writing a compound file is a much larger problem and nothing here wants to.
///
/// ## The two allocation tables
///
/// A stream smaller than the header's mini-stream cutoff (4,096 bytes in every file seen)
/// is stored in 64-byte mini-sectors carved out of one ordinary stream hanging off the root
/// entry; everything larger is stored in full sectors chained through the FAT. Both paths
/// matter here and are exercised by a single encrypted workbook: `EncryptionInfo` is small
/// and `EncryptedPackage` is not.
public struct CompoundFile: Sendable {

    /// The largest value that names a real sector; anything above is a marker.
    private static let maxRegularSector: UInt32 = 0xFFFF_FFFA

    /// The compound file signature.
    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// One entry in the container's directory.
    struct DirectoryEntry: Sendable {
        let name: String
        let objectType: UInt8
        let startingSector: UInt32
        let streamSize: UInt64
    }

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let directory: [DirectoryEntry]
    private let miniStream: [UInt8]

    /// The names of every stream in the container.
    public var streamNames: [String] {
        directory.filter { $0.objectType == 2 }.map(\.name)
    }

    /// Reads a compound file's structure.
    ///
    /// - Parameter data: The whole file.
    /// - Throws: ``CompoundFileError`` if it is not a compound file, or is damaged.
    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == Self.signature else {
            throw CompoundFileError.notACompoundFile
        }
        guard bytes.count >= 512 else { throw CompoundFileError.truncated("its 512-byte header") }
        self.bytes = bytes

        let sectorShift = try Self.u16(bytes, 0x1E)
        let miniSectorShift = try Self.u16(bytes, 0x20)
        // Version 3 shifts by 9 (512-byte sectors) and version 4 by 12 (4,096). Anything
        // else is not a shift this format defines, and shifting by it would be undefined
        // rather than merely wrong.
        guard sectorShift == 9 || sectorShift == 12 else {
            throw CompoundFileError.malformed("sector shift \(sectorShift)")
        }
        guard miniSectorShift == 6 else {
            throw CompoundFileError.malformed("mini sector shift \(miniSectorShift)")
        }
        sectorSize = 1 << Int(sectorShift)
        miniSectorSize = 1 << Int(miniSectorShift)
        miniStreamCutoff = Int(try Self.u32(bytes, 0x38))

        let firstDirectorySector = try Self.u32(bytes, 0x30)
        let firstMiniFATSector = try Self.u32(bytes, 0x3C)
        let firstDIFATSector = try Self.u32(bytes, 0x44)

        // --- the FAT, via the DIFAT that indexes it ---------------------------------
        var fatSectors: [UInt32] = []
        for index in 0..<109 {
            let sector = try Self.u32(bytes, 0x4C + index * 4)
            if sector <= Self.maxRegularSector { fatSectors.append(sector) }
        }
        // Continuation DIFAT sectors, each ending with a pointer to the next. Bounded by
        // the sector count: a chain longer than the file has sectors is a cycle.
        let perDIFAT = sectorSize / 4 - 1
        var nextDIFAT = firstDIFATSector
        var difatVisited = 0
        let sectorCount = max(1, (bytes.count - 512) / sectorSize)
        while nextDIFAT <= Self.maxRegularSector, difatVisited <= sectorCount {
            let base = 512 + Int(nextDIFAT) * sectorSize
            for index in 0..<perDIFAT {
                let sector = try Self.u32(bytes, base + index * 4)
                if sector <= Self.maxRegularSector { fatSectors.append(sector) }
            }
            nextDIFAT = try Self.u32(bytes, base + perDIFAT * 4)
            difatVisited += 1
        }
        guard difatVisited <= sectorCount else {
            throw CompoundFileError.malformed("DIFAT chain does not terminate")
        }

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * (sectorSize / 4))
        for sector in fatSectors {
            let base = 512 + Int(sector) * sectorSize
            for index in 0..<(sectorSize / 4) {
                fat.append(try Self.u32(bytes, base + index * 4))
            }
        }
        self.fat = fat

        // --- the mini-FAT ------------------------------------------------------------
        var miniFAT: [UInt32] = []
        for sector in try Self.chain(from: firstMiniFATSector, through: fat) {
            let base = 512 + Int(sector) * sectorSize
            for index in 0..<(sectorSize / 4) {
                miniFAT.append(try Self.u32(bytes, base + index * 4))
            }
        }
        self.miniFAT = miniFAT

        // --- the directory -----------------------------------------------------------
        var directory: [DirectoryEntry] = []
        for sector in try Self.chain(from: firstDirectorySector, through: fat) {
            let base = 512 + Int(sector) * sectorSize
            for slot in 0..<(sectorSize / 128) {
                let offset = base + slot * 128
                guard offset + 128 <= bytes.count else {
                    throw CompoundFileError.truncated("a directory entry")
                }
                let nameLength = Int(try Self.u16(bytes, offset + 0x40))
                // The length counts bytes and includes the UTF-16 null terminator, so a
                // zero-length or over-long name is a damaged entry rather than a short one.
                let characters = nameLength >= 2 ? (nameLength - 2) / 2 : 0
                var scalars: [UInt16] = []
                for index in 0..<characters {
                    scalars.append(try Self.u16(bytes, offset + index * 2))
                }
                directory.append(DirectoryEntry(
                    name: String(decoding: scalars, as: UTF16.self),
                    objectType: bytes[offset + 0x42],
                    startingSector: try Self.u32(bytes, offset + 0x74),
                    streamSize: try Self.u64(bytes, offset + 0x78)))
            }
        }
        guard let root = directory.first, root.objectType == 5 else {
            throw CompoundFileError.malformed("no root directory entry")
        }
        self.directory = directory

        // The mini stream is an ordinary stream hanging off the root entry; every small
        // stream is carved out of it, so it has to be read before any of them can be.
        var miniStream: [UInt8] = []
        for sector in try Self.chain(from: root.startingSector, through: fat) {
            let base = 512 + Int(sector) * sectorSize
            guard base + sectorSize <= bytes.count else {
                throw CompoundFileError.truncated("the mini stream")
            }
            miniStream.append(contentsOf: bytes[base..<(base + sectorSize)])
        }
        self.miniStream = miniStream
    }

    /// The bytes of one named stream.
    ///
    /// - Parameter name: The stream's directory name, such as `EncryptedPackage`.
    /// - Returns: Exactly the declared number of bytes, with the sector padding removed.
    /// - Throws: ``CompoundFileError/noSuchStream(_:)`` if the container has no such stream.
    public func stream(named name: String) throws -> Data {
        guard let entry = directory.first(where: { $0.name == name && $0.objectType == 2 }) else {
            throw CompoundFileError.noSuchStream(name)
        }
        let size = Int(entry.streamSize)
        // Which table the stream lives in is decided by its size, not by anything in its
        // own entry — this is the distinction a reader that only walks the FAT gets wrong.
        let small = size < miniStreamCutoff
        let unit = small ? miniSectorSize : sectorSize
        var out: [UInt8] = []
        out.reserveCapacity(size)
        for sector in try Self.chain(from: entry.startingSector,
                                     through: small ? miniFAT : fat) {
            let base = small ? Int(sector) * unit : 512 + Int(sector) * unit
            let source = small ? miniStream : bytes
            guard base + unit <= source.count else {
                throw CompoundFileError.truncated("stream \(name)")
            }
            out.append(contentsOf: source[base..<(base + unit)])
            if out.count >= size { break }
        }
        guard out.count >= size else { throw CompoundFileError.truncated("stream \(name)") }
        return Data(out.prefix(size))
    }

    // MARK: - Walking

    /// Follows a sector chain to its end.
    ///
    /// Every sector visited is remembered, so a table that points back into itself is
    /// reported rather than followed for ever. These files come from outside and a
    /// malformed one must not be able to hang a scan.
    private static func chain(from start: UInt32, through table: [UInt32]) throws -> [UInt32] {
        var sectors: [UInt32] = []
        var visited: Set<UInt32> = []
        var current = start
        while current <= maxRegularSector {
            guard !visited.contains(current) else {
                throw CompoundFileError.malformed("sector chain loops at \(current)")
            }
            visited.insert(current)
            sectors.append(current)
            guard Int(current) < table.count else {
                throw CompoundFileError.malformed("sector \(current) is outside the table")
            }
            current = table[Int(current)]
        }
        return sectors
    }

    // MARK: - Little-endian reads, bounds-checked

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw CompoundFileError.truncated("a 16-bit field at \(offset)")
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw CompoundFileError.truncated("a 32-bit field at \(offset)")
        }
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[offset + index]) }
        return value
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else {
            throw CompoundFileError.truncated("a 64-bit field at \(offset)")
        }
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}
