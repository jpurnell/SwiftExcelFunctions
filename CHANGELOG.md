# Changelog

All notable changes to SwiftExcelFunctions will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-09-05

Two things at once: the function coverage that closes the corpus, and the shape
change that makes positional functions correct.

### Fixed

- **`VLOOKUP` and `HLOOKUP` read their table's width from the table.**

  They inferred it from `col_index_num` by testing which divisors of the element
  count came out even. `VLOOKUP("b", A1:D3, 3, FALSE)` answered `#N/A` where Excel
  answers `"b3"` — twelve elements divide evenly by three, so a four-column table
  was read as three columns. Column 2 always worked, which is why this went
  unnoticed: the answer is the element after the key whatever width you assume.

- **`INDEX` reads a row and a column.** `INDEX(block, 2, 1)` answered `2`, the
  second element of the flat list, where the answer is `4`. The old code was
  candid: *"Actually, this doesn't work without knowing dimensions."*

- **`INDEX` and `MATCH` no longer count past the end of their own range.** An
  empty cell used to be dropped when the range was read, so every position after
  it shifted up one. `INDEX(A1:A4, 3)` with `A2` empty answered `40` instead of
  `30`.

- **Out-of-bounds indices answer `#REF!`**, not `#N/A`. A guessed width cannot
  tell "past the edge" from "not found".

### Added

- `BuiltinArrayFunctions` — `TRANSPOSE` and `COUNTBLANK`.

  `TRANSPOSE` exchanges rows and columns, blanks included. It does **not** spill:
  evaluation yields one value for one cell, so a transposed array is useful inside
  another formula and has nowhere to go on its own.

  `COUNTBLANK` was previously unwritable rather than merely absent — the old read
  dropped empty cells, so it would have been handed none of the things it counts.

- `XIRR`, bound to BusinessMath. Excel's argument order is values then dates, the
  reverse of BusinessMath's.
- `YEARFRAC`, `COVARIANCE.P`, `COVARIANCE.S`, `COVAR`, `NORM.S.INV`.
- `RAND` and `RANDBETWEEN`, deterministic by construction: the package supplies no
  randomness, and without a source `RAND()` answers `#VALUE!`.
- `ADDRESS`, `COLUMN`, `ROW`, `INDIRECT`, `OFFSET`, `ISREF`, and an
  `EvaluationContext` for the functions that need to know where they were called.
- `SUMPRODUCT`, `SUMSQ`, `CHOOSE`, `LOOKUP`.
- Information and date/time functions, and the modern spellings Excel 2010
  introduced.

### Changed

- **`CellValue.array` carries a `CellMatrix`** (SwiftExcelCore 0.3.0). Ranges read
  as rectangles: `A1:A3` is 3 rows by 1, and its empty cells are blanks in place.
- `SeededRandomSource` is generic over the stdlib's `RandomNumberGenerator`,
  defaulting to `DeterministicRNG`.
- `RANDBETWEEN` draws an unbiased integer instead of scaling a double across the
  span, which is modulo bias in another form.
- Function groups renamed for a coherent order: Logic, DateTime, Navigation.

### Breaking

- `CellValue.array`'s payload type. Pattern matches that bind it need updating;
  bare `case .array:` matches do not.
- `INDEX(block, n)` with one index now returns the whole *row*, which is Excel's
  actual semantics and newly expressible. Callers relying on the old flat
  positional reading will see a different value.

## [0.2.0] - 2026-09-04

### Added
- `FormulaAST.missing` evaluates to `.blank`. An argument that is not there is not zero: `ADDRESS`
  reads an omitted fourth argument as its default reference style and `IFERROR` reads an omitted
  second as empty, so blank is what gets passed and the interpretation stays with the function.

### Changed
- SwiftExcelCore **0.2.0** and, for tests only, SwiftXLSX **0.14.0** — the release whose parser
  produces `.missing` and whole-column ranges.


## [0.1.0] - 2026-09-04

Excel's function library, extracted from SwiftXLSX. One registry, asked for any function by the
name Excel uses — a caller never needs to know which package computes it.

### Added

- **73 Excel functions** across eight areas: aggregation, math, statistics, financial, date,
  logical, lookup, text.
- `FunctionRegistry` — copy-on-write, with `.builtin` preloaded and `register(_:)` for additions.
- `ExcelFunction` — a name, an arity, and a closure over values.
- `FormulaEvaluator` — walks a `FormulaAST`, resolving cell references through a
  `CellValueProvider`, named ranges through a `NameResolver`, and calls through the registry.
- `EvalError` — evaluation's own error type, mapped to `ExcelError` at the boundary.

### Notes

**No file format.** Give it a formula tree and any `CellValueProvider` and it evaluates — no
archive, no workbook, no I/O. That is what makes it usable alone, and what makes a binding
testable against a published value without opening a spreadsheet.

**The mathematics is delegated.** BusinessMath owns it; a second `NPV` that could disagree with
the first is the failure this arrangement exists to prevent. What belongs here is Excel's
semantics: argument order, type coercion, error propagation, and the sign conventions Excel
applies where a mathematics library correctly does not.

Moved unchanged, with their tests — 546 passing, including 49 parse-and-evaluate integration
cases that use SwiftXLSX's parser through a test-only dependency.

### Coverage

Against Microsoft's 519 documented worksheet functions: 72 present, 84 bindable against
mathematics BusinessMath already computes, 6 verified absent, 10 out of scope, 347 unreviewed.
Risk Solver's 295 PSI functions: 50 bindable, 13 role declarations rather than functions.
See `project/plans/excel_function_coverage_matrix.tsv`.

[Unreleased]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.2.0...HEAD
[0.3.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.1.0
