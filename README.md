# SwiftExcelFunctions

Part of the SwiftExcel package family. See `project/master_plan.md` for scope and roadmap, and
`BusinessMathExcel/project/plans/proposals/PROPOSAL_swift_excel_architecture.md` for why the
family is split the way it is.

**Status:** 1.0.0-alpha.1. **It agrees with Excel.** Over 300 real workbooks and
**4,524,171 comparable cells the agreement is 99.999978%** — one disagreement, and it is a
workbook that contradicts its own cached values rather than a defect here.

**Every function Microsoft documents is either implemented or out of scope with a written
reason** — 494 `have`, 25 out of scope, nothing left unreviewed. `LAMBDA` shipped whole.
Sixteen conformance rounds have settled facts about Excel that Microsoft documents one side
of, most recently that a blank lookup value is `0`, that a negative base under an odd root has
a real value, and that argument order decides which error propagates.

**Why alpha.** The API has been stable throughout, but nothing has yet consumed it as a
*client* rather than as a test harness. A consumer resolves a pre-release the way this package
resolves BusinessMath — a range whose own lower bound carries the identifier, or an exact pin.
A bound without one will not reach it.

- **494** of Microsoft's 519 documented worksheet functions. The other 25 need a live data
  service, a network fetch, or a layer this package deliberately does not have — see
  `project/docs/technical/LookupOutOfScope.md`.
- **Frontline Risk Solver's `Psi*` functions**, with every row of that source now classified
  too — 189 `have`, 71 out of scope with a reason each. The bucket that "needs a simulation
  engine rather than a classification" closed on 2026-09-19.

Coverage is tracked in `project/plans/proposals/Excel conformance/excel_function_coverage_matrix.tsv`,
reconciled against the live `FunctionRegistry` rather than maintained by hand. The
reconciliation is checked rather than asserted — `CoverageReconciliationTests` fails if a row
marked `have` names a function the registry does not answer to, and fails the other way if a
row marked `new` turns out to be implemented. The Excel side carries all 519 documented
functions, which is what makes "473 of 519" a coverage figure rather than a ratio of the rows
somebody happened to type in.

That check earns its keep. It last found seven byte functions and `PsiXtoP` implemented but
still filed as outstanding, and one Psi row entered twice under two spellings of the same
name — which Excel, being case-insensitive about function names, cannot distinguish. Until
those were fixed the two sides differed by eight, and the matrix under-reported its own
coverage.

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
  cached for it in real workbooks. **99.999978%** agreement over **4,524,171** comparable cells
  in 300 workbooks: 1 differed, 0 refused, 0 threw.

  That figure is the project's main instrument, and it has been wrong in this package's favour
  before. Three oracle blind spots were closed in the run-up to 1.0 — the tool's own accuracy
  was the binding constraint about as often as the library's was.

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

## License

**AGPLv3, with a commercial licence available** — see [LICENSE](LICENSE) and
[LICENSING.md](LICENSING.md).

Free to use, modify and distribute if you publish your source. If you want to
embed this in a proprietary product or offer it as a hosted service without that
obligation, a commercial licence removes the copyleft terms.

The network clause (AGPLv3 §13) is deliberate: running this as a service is a
form of use the copyleft is meant to reach.

The permissive layers of the family — SwiftExcelCore, SwiftXLSX, SwiftZIP — are
Apache 2.0 and carry no copyleft.
