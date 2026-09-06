# Changelog

All notable changes to SwiftExcelFunctions will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **The coverage matrix is reconciled against the registry rather than by hand.**

  `project/plans/excel_function_coverage_matrix.tsv` had not moved since it was
  scaffolded, so it still described the pre-extraction package: 72 functions, all
  of them attributed to SwiftXLSX. 163 rows were wrong.

  It is now generated against `FunctionRegistry` itself — every group's `all`,
  plus the alias table, so `STDEV.S` is covered by whatever covers `STDEVS`. Of
  Excel's 519 documented functions, **160 `have`** (was 72), 57 bindable, 286
  unreviewed; of Risk Solver's 295, three markers implemented and 50 bindable.
  Nothing previously claimed has been lost — the check runs both directions.

  The `provider` column now names the group that registers a function instead of
  a scaffold-time guess at which BusinessMath symbol might supply it. Several of
  those guesses were wrong (`NORM.S.INV` was attributed to
  `NewsvendorModel.optimalQuantity`), and the real call is in the binding's own
  source, where it cannot drift from the code.

  A header row names the eight columns, which were previously positional.

  `calls` and `books` are **not** reconciled and are flagged as such in the
  master plan: they are the original corpus scan, and the recent census disagrees
  with them. Refreshing them needs a full-corpus run, which currently traps
  partway through.

## [0.5.0] - 2026-09-05

### Added

- **`FormulaEvaluator.spill(_:over:cells:names:…)`** — evaluates one formula and
  distributes its result across a span.

  An array formula is entered over a range, evaluates once, and its result fills
  the whole rectangle. `evaluate` answers with a value — for an array formula, a
  whole `CellMatrix` — and something still had to say which cell gets which
  element. This does, reconciling the shapes through
  `CellMatrix.spilled(toRows:columns:)`.

  It returns an **assignment**, not a mutation: this package has no workbook to
  write into and takes no dependency on one. `Worksheet.apply(_:)` in SwiftXLSX
  consumes exactly this shape, so the two halves meet without either library
  knowing the other exists.

  A scalar result is a 1×1 rectangle, so broadcasting handles it with no special
  case — including an error, which Excel shows in every cell of a failed array
  formula rather than only the first.

### Changed

- Depends on SwiftExcelCore `0.5.0` and SwiftXLSX `0.21.0`.

## [0.4.0] - 2026-09-05

### Fixed

- **Whole-column references evaluate instead of erroring.**

  `SUM($A:$A)`, `VLOOKUP(x, $A:$B, 2, FALSE)` and `INDEX($A:$A, 3)` all answered
  `#VALUE!` in 0.3.0, which bounded a range read at 262,144 cells. The corpus writes
  that notation 87,773 times in `VLOOKUP` alone. SwiftExcelCore 0.4.0 replaced the
  bound with a clip to the sheet's own data, so the read is affordable and the
  answer is right. Positions still count from row 1, so `INDEX($A:$A, 3)` is the
  third row.

### Changed

- Depends on SwiftExcelCore `0.4.0` and SwiftXLSX `0.17.0`.
- The four evaluator sites that turned a refused range into `#VALUE!` are gone —
  `matrix(in:)` no longer refuses anything.

### Breaking

- A `CellValueProvider` must now answer `lastPopulatedCell()`. A dictionary-backed
  provider does it in three lines from its own keys; a provider that does not know
  says so with `CellRef.lastOnSheet`, which clips nothing.

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
[0.5.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.1.0
