# SwiftExcelFunctions

Part of the SwiftExcel package family. See `project/master_plan.md` for scope and roadmap, and
`BusinessMathExcel/project/plans/proposals/PROPOSAL_swift_excel_architecture.md` for why the
family is split the way it is.

**Status:** 0.7.0; 269 functions registered, 909 tests, quality gate 45/45 at 0/0.

- **160** of Microsoft's 519 documented worksheet functions.
- **109** of Frontline Risk Solver's `Psi*` functions — 106 of its 113 distribution rows — so a
  workbook built with Risk Solver can be read without the add-in.

Coverage is tracked in `project/plans/proposals/Excel conformance/excel_function_coverage_matrix.tsv`,
reconciled against the live `FunctionRegistry` rather than maintained by hand.

## Two products

| Product | What it does | Reads files? |
|---|---|---|
| **`SwiftExcelFunctions`** | The function library and evaluator. | **No** — works against a `CellValueProvider`, so it evaluates a sheet that never came from a file. |
| **`WorkbookAudit`** | Audits a spreadsheet the way a quality gate audits code. | Yes — its own target for exactly that reason. |

`WorkbookAudit` ships two checkers, each with the false-positive rate that decided
whether it is on by default:

- **`circular-reference`** (enabled) — cells depending on themselves, directly or
  through a chain, across the whole workbook rather than a sheet at a time. **0
  findings across 6 real workbooks.**
- **`consistency`** (opt-in) — one cell in a run differing from its neighbours,
  compared modulo relative offset so a copied formula counts as the same shape. It
  finds real defects, and it produced **249 findings across 33% of six real
  workbooks**. A checker firing that broadly gets a validator switched off wholesale,
  taking the checker that *was* right with it — so it is opt-in until the rate comes
  down.

## Installation

```swift
.package(url: "https://github.com/jpurnell/SwiftExcelFunctions", from: "0.7.0")
```

Requires Swift 6 and macOS 14. Depends on SwiftExcelCore for the spreadsheet vocabulary and
BusinessMath for the mathematics; SwiftXLSX is a test-only dependency.

## The family

| Package | Holds |
|---|---|
| **SwiftExcelCore** | the vocabulary — `CellValue`, `CellRef`, `FormulaAST`, `ExcelError`, `CellValueProvider` |
| **SwiftXLSX** | syntax and storage — lexer, parser, serializer, reader/writer, styles |
| **SwiftExcelFunctions** | the function library and evaluator |
| **BusinessMath** | the mathematics, and only the mathematics |

## Correctness

Two suites, deliberately overlapping, because they fail for different reasons:

- **`MicrosoftSpecificationTests`** — the rules taken from Microsoft's published function
  reference. Runs on a clean checkout, on the machine of someone who has never seen a corpus.
  Every expected value is quoted from a published worked example or computed from the documented
  formula; none is taken from what this package currently returns.
- **`ExcelOracleTests`** — every formula we can evaluate, checked against the value Excel itself
  cached for it in real workbooks. **99.62%** agreement over 155,897 comparable cells.

Randomness is never taken from the system: a caller supplies a `RandomSource`, and without one
`RAND()` and every Psi distribution answer `#VALUE!` rather than inventing a draw. The same seed
gives the same workbook twice.

The oracle reads private workbooks and takes minutes, so it is opt-in:

```
BUSINESSMATHEXCEL_ORACLE=1 swift test          # or set BUSINESSMATHEXCEL_CORPUS to a path
```

Where the two disagree with each other, `project/decisions/architecture_decisions.md` (ADR-001)
governs: Excel is the specification. Where Excel departs from a published standard, we match
Excel under the Excel-facing name and expose the standard beside it, named for the standard.

## Building

```
swift build && swift test
```
