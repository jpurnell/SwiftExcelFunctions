# SwiftExcelFunctions

Part of the SwiftExcel package family. See `project/master_plan.md` for scope and roadmap, and
`BusinessMathExcel/project/plans/proposals/PROPOSAL_swift_excel_architecture.md` for why the
family is split the way it is.

**Status:** 0.5.0 released; 163 functions registered, 782 tests, quality gate 45/45 at 0/0.

Of Excel's 519 documented worksheet functions, 160 are implemented and 57 more are bindable
against mathematics BusinessMath already computes. Coverage is tracked in
`project/plans/excel_function_coverage_matrix.tsv`, which is reconciled against the live
`FunctionRegistry` rather than maintained by hand.

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
