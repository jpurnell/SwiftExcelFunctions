import SwiftExcelCore

/// Excel's function library, in Swift.
///
/// One registry, asked for any function by the name Excel uses. A caller never
/// needs to know which package computes a given name — that `AVERAGE` is
/// arithmetic and `NORM.DIST` is a distribution is an implementation detail, and
/// leaking it into the API would be the wrong contract.
///
/// ## No file format
///
/// Hand it a `FormulaAST` and any `CellValueProvider` and it evaluates. No ZIP, no
/// workbook, no I/O. That is what makes it usable on its own, and what makes it
/// testable: an argument order can be asserted against a published value without
/// opening a spreadsheet.
///
/// ## The mathematics is delegated
///
/// BusinessMath owns it. A second `NPV` that could disagree with the first is the
/// failure this arrangement exists to prevent. What belongs here is Excel's
/// *semantics* — argument order, coercion, error propagation, and the sign
/// conventions Excel applies and a mathematics library correctly does not.
public enum SwiftExcelFunctions {

    /// The package version, as a human-readable string.
    public static let version = "0.1.0-dev"
}
