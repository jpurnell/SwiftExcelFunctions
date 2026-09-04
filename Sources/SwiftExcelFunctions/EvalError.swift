import SwiftExcelCore
/// Internal errors raised during function evaluation, mapped to `ExcelError` at the boundary.
enum EvalError: Error {
    /// The argument cannot be converted to the required type.
    case typeMismatch
    /// An Excel error value was encountered in an argument.
    case excelError(ExcelError)
    /// A numeric domain error (maps to `#NUM!`).
    case numError
    /// Division by zero (maps to `#DIV/0!`).
    case div0Error
}
