# Changelog

All notable changes to SwiftExcelFunctions will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The Excel oracle.** Every formula in a real workbook is checked against the
  value Excel itself cached for it — the strongest oracle this project has, since
  it was produced by the specification, on files nobody wrote for us. Precedents
  resolve to *Excel's* cached values rather than ours, so one wrong cell is one
  finding instead of a cascade.

  Opt-in via `BUSINESSMATHEXCEL_ORACLE=1` or `BUSINESSMATHEXCEL_CORPUS`, because
  it reads private workbooks and takes minutes; the gate runs `swift test`, and a
  suite that takes ten minutes is a suite that gets skipped.

  Agreement over 155,897 comparable cells moved **46.6% → 99.62%** across this
  release. Volatile functions and the Monte Carlo family are excluded rather than
  compared — a cached `RAND()` records an afternoon in 2013.

- **`MicrosoftSpecificationTests`** — ~105 tests taking the same rules from the
  published function reference, runnable on a clean checkout by someone who has
  never seen the corpus. The oracle answers "how often do we agree", which is a
  number you either trust or you do not; these say what the rule *is*. Every
  expected value is quoted from a published worked example or computed from the
  documented formula, and none is taken from what this package currently returns.

- **A corpus census** — what we *cannot* answer, which the oracle cannot see. An
  unregistered function answers `#NAME?`, never disagrees about a value, and
  barely moves the agreement number. It walks the parsed AST rather than the
  formula text: a first pass done with a regex reported nine sheet names
  containing parentheses as unknown functions, and missed `STDEV.S` — 2.2 million
  calls — by taking the registry from a grep that never saw the alias table.

- **Text, date and reference functions**, chosen by what the corpus calls rather
  than by what a matrix lists: `SUBSTITUTE` (230,092 calls), `FIND` (102,168),
  `SEARCH` with a real wildcard matcher, `PROPER`, `CLEAN`, `NUMBERVALUE`,
  `WORKDAY`, `DATEVALUE`, `TIME`, `ROWS`, `COLUMNS`, `HYPERLINK`.

- **Maths bridged to Foundation** rather than rewritten: `SIN`, `COS`, `TAN`,
  `ASIN`, `ACOS`, `ATAN`, `ATAN2`, `LOG10`, `TRUNC`, `PRODUCT`, `GCD`, `LCM`.
  These are libm's and Excel's contract is C's, so the bridging is the whole job.
  Note `ATAN2` takes **x first**, the reverse of C and most languages.

- **Statistics bridged to BusinessMath**: `SLOPE`, `INTERCEPT`, `NORM.DIST`,
  `NORM.S.DIST`, `NORM.INV`, `COVARIANCE.P/S`, `PERCENTILE.INC`, `STDEV.P/S`,
  `VAR.P/S`, `XIRR`, `YEARFRAC`. Excel takes `SLOPE(known_y, known_x)` and
  BusinessMath takes `slope(x, y)` — reversed it returns a real, plausibly-sized,
  wrong number, which is what the bindings exist to prevent.

- **`XLOOKUP`**, the generalisation of `VLOOKUP`/`HLOOKUP`: keys and results as
  separate ranges, which is what lets the result sit *left* of the key. Its
  default is exact where `VLOOKUP`'s is approximate.

- **`YEARFRAC`** computing every documented basis, and the legacy statistical
  spellings, `TRUE()`/`FALSE()`, `UNICODE`/`UNICHAR`, the base conversions,
  `RANK`/`RANK.EQ`/`RANK.AVG`, and `CELL`.

- **Risk Solver markers** — `PsiOutput`, `PsiBaseCase`, `PsiName`. The rest of the
  family is Monte Carlo; `PROPOSAL_psi_bindings.md` records the measured
  signatures and why the cached values are not oracles.

- **`GETPIVOTDATA`** answering `#REF!`. Its result is looked up in a pivot cache
  this family does not read. Deliberately not `#NAME?`: the function exists and
  its name is known — what is missing is the data behind it, and someone
  debugging a sheet needs to tell those apart.

- **ADR-001** (`project/decisions/architecture_decisions.md`) — Excel is the
  specification. Where Excel departs from a published standard we match Excel
  under the Excel-facing name and expose the standard beside it, named for the
  standard. Records what it rules out, which is the part that decays first.

### Changed

- **BusinessMath 2.11.0 → 2.14.0, and three known defects closed with it.**

  2.14.0 closed BusinessMath's Risk Solver work list, and the pin was `from:`, so
  `Package.resolved` still held 2.11.0 and nothing could see it.

  The bump made three tests fail by *passing*: `actual/360`, `actual/365` and
  `actual/actual` had each carried an `XCTExpectFailure` for a daylight-saving
  hour — BusinessMath measured elapsed time through a calendar in the machine's
  local zone, so an interval crossing a DST boundary gained an hour, moving every
  such accrual by two parts in ten thousand. Fixed upstream; the three guards are
  removed. Their date pairs are deliberately kept, because a test that never
  crosses a boundary cannot see the defect come back.

  **The NASD February rule is still open** — Excel says 301/360 for
  2020-02-29 → 2020-12-31 and BusinessMath says 302/360. That is basis 0, which
  every one of the corpus's 3,425 `YEARFRAC` calls uses, so it remains the whole
  of the outstanding disagreement list.

- **The PSI half of the coverage matrix is reconciled against BusinessMath
  2.14.0.** All 113 distribution rows are now resolved — **56 bindable, 57 absent
  upstream** — where 230 of the 295 PSI rows had been `unreviewed`. Rows with no
  mathematics upstream are marked `new`, with `provider` reading `absent from
  BusinessMath 2.14.0`, so the file says what was checked rather than what was
  assumed.

  The nine distributions the corpus actually calls are **all bindable**, covering
  1,166 of the family's 1,950 corpus calls. What is absent is not reached by the
  corpus at all: 28 percentile-fit `*Alt` parameterisations needing a fitting
  solve rather than a sampler, 7 time-series beyond the `AR1`/`GARCH11` pair, 10
  data-source functions, and 12 genuinely missing distributions.

  **None of them is bound yet.** Three Psi functions are registered — the markers.

- **The registry resolves through `_xll.` and `_xlfn.`.** Neither is part of a
  function's identity — one marks an add-in, the other a function newer than the
  file format it was saved into — and Excel displays both without the prefix.
  Without this, `_xlfn.SUMIFS` was unknown to us for a purely clerical reason.

- **The coverage matrix is reconciled against the registry rather than by hand.**
  `project/plans/excel_function_coverage_matrix.tsv` had not moved since it was
  scaffolded, so it still described the pre-extraction package: 72 functions, all
  attributed to SwiftXLSX. 163 rows were wrong — which for the document that
  scopes the work understates what exists and points effort at things already
  done.

  Of Excel's 519 documented functions, **160 `have`** (was 72), 57 bindable, 286
  unreviewed; of Risk Solver's 295, three markers and 50 bindable. The check runs
  both directions, so nothing previously claimed has been lost. `provider` now
  names the registering group instead of a scaffold-time guess at which
  BusinessMath symbol might supply it — several guesses were wrong. A header row
  names the eight previously-positional columns.

  `calls` and `books` are deliberately **not** reconciled and are marked as an
  ordering hint rather than a measurement: the recent census disagrees with them,
  and refreshing needs a full-corpus run that currently traps partway through.

- **The alias table's fields say which direction they run.** It reads
  `(alias, existing)` and was labelled `(modern, legacy)`, which describes the
  original five and misleads on every entry since. Four new entries silently did
  nothing until this was corrected.

- **Inventory tests assert membership, not a count.** A count says something
  changed without saying what, and fails identically whether a function arrived
  or vanished.

### Fixed

- **`VLOOKUP`, `HLOOKUP` and `MATCH` propagate an error argument.** All 40 of
  `HLOOKUP`'s corpus disagreements were `ours #N/A, Excel #NAME?` — a lookup
  whose *key* was already an error. Answering `#N/A` says "looked and did not
  find" about a lookup that never happened, and loses the only clue to where the
  trouble started.

- **`NPV` accepts ranges.** It required a number per argument, so any range
  answered `#VALUE!` — 126 corpus disagreements.

- **`XIRR` converges to a tolerance scaled to the model.** BusinessMath's test is
  absolute in currency units, defaulting to 1e-4, so its meaning changed with the
  size of the model and the binding never overrode it.

  That did not move the answer, which turned out to be the finding. On the corpus
  cell, `XNPV` at our rate is `2.18e-11` and at Excel's is `-0.00152`: **ours is
  the root and Excel stopped early**, 3.9e-8 away — four times the accuracy it
  documents for itself. The comparison band for iterative functions is therefore
  1e-6 rather than the documented 1e-8, and says why.

- **The oracle compares a spilled anchor correctly.** One formula filling a span
  evaluates once and each cell shows its own element; only the top-left carries
  the formula, so a whole matrix was being compared against a single cached value.

### Known upstream

Day-count bases 0–3 are wrong and are documented as wrong rather than patched
here — a second implementation of a day count is what the package split exists to
prevent. `thirty360` misses the NASD February rule (Excel 301/360, ours 302/360),
and `actual365`/`actual360`/`actualActual` gain an hour across a daylight-saving
boundary. BusinessMath 2.11.0 shipped the new conventions but neither fix. These
are the remaining corpus disagreements: 260 `IF`, 202 `YEARFRAC`, 142 `YEAR`,
140 `AND` — all the same two defects and their wrappers.

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
