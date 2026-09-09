# What the `calls` and `books` columns mean — and why nobody currently knows

**Recorded 2026-09-09. Mostly resolved the same day** — see §"What it was". Read this
before using `excel_function_coverage_matrix.tsv`'s counts to argue for anything, and in
particular before reading a zero out of them.

## The problem

At least two corpus measurements exist in this repository. They are not labelled, they
disagree, and nothing records which sweep produced the matrix.

| Function | Source comment | Matrix (`calls` / `books`) |
|---|---|---|
| `STDEV.S` | 86,410 calls across **79** workbooks — `FunctionRegistry.swift:134` | 86,410 / **42** |
| `PsiOutput` | **167** times across **41** workbooks — `BuiltinRiskSolverFunctions.swift` | **24** / **11** |
| `PsiMean` | 28 calls across 5 real workbooks | 31 / 13 |
| `PsiStdDev` | 12 calls across 2 real workbooks | 4 / 3 |
| `PsiPercentile` | 10 calls in 1 workbook | 28 / 4 |
| `PsiTarget` | 7 calls across 3 workbooks | 5 / 2 |

## Why the obvious explanations do not hold

- **Not a transcription slip.** Three of the four statistics' comment values (12, 10, 7)
  appear nowhere among those matrix rows. `PsiMean`'s 28 equals `PsiPercentile`'s matrix
  count, but one hit in four on small integers is chance.
- **Not a subset.** The six simulation models cannot sit inside the matrix's population:
  `PsiStdDev` reports 12 calls against the matrix's 4, and `PsiTarget` reports 3 *workbooks*
  against the matrix's 2. A subset cannot exceed its superset, and a workbook count is the
  harder of the two to miscount.
- **Not a consistent scaling either.** `STDEV.S`'s call count agrees **exactly** — 86,410 in
  both — while its book count does not, 79 against 42. `PsiOutput` agrees on neither, and
  disagrees by roughly 7× on calls and 3.7× on books.
- **They disagree on rank, not just magnitude.** The `PsiOutput` comment says it appears in
  "more workbooks than any other member of the family." Under the matrix it does not — 11
  books, against `PsiTriangular`'s 17. Two measurements can differ on counts; differing on
  *which function is most widespread* means they are not measuring the same population.

An exact agreement on one call count alongside a 7× disagreement on another is the part no
single explanation covers, and it is why this is written down rather than reasoned away.

## What is affected

Any argument from demand. In particular: **"no unbound row in the matrix has any corpus
demand"** (established 2026-09-09, commit `84d92c7`) is true *of the matrix column* and
inherits this uncertainty. It is still the best number available, and it should be quoted
with its source rather than as a fact about the workbooks.

The `status` column is unaffected — it is verifiable against the source tree, and was
corrected for five rows in `84d92c7`.

## What it was: the two halves have different denominators

Group the matrix by its source tag and take the maxima. The answer is in the file:

| Tag | Rows | Rows with any books | Max books | Max calls |
|---|---|---|---|---|
| `EXCEL` | 519 | 69 | **338** (`SUM`) | 168,779 (`IFERROR`) |
| `PSI` | 296 | 20 | **17** (`PsiTriangular`) | 95 (`PsiBaseCase`) |

A ceiling of seventeen workbooks across an entire function family, against three hundred and
thirty-eight for the other, is not sampling variation. **The two halves were swept over
different sets of files**, so every comparison across that line has been comparing
denominators. Found by the BusinessMath session; confirmed here against this file, with
identical maxima.

That resolves most of the table above:

- **`PsiOutput` 167/41 against 24/11 is not a contradiction.** The matrix's Psi half cannot
  report 41 books for anything — its ceiling is 17. The comment came from a larger Psi sweep.
- **The rank disagreement is explained.** "More workbooks than any other member of the
  family" is true under that sweep and false under this half. Different populations.
- **`STDEV.S` remains open**, and it is the interesting one, because it sits entirely inside
  the `EXCEL` half: the same extraction produced 86,410 in both places while the book
  denominator differs, 79 against 42.

### A zero is not a zero

This is the part that bears on sequencing:

- **An `EXCEL` zero means absent from a population reaching 338 workbooks.** Strong evidence.
  `COMPLEX`, all 25 `IM*` rows and all four `FORECAST.ETS*` rows are `EXCEL` rows, so their
  zero demand is well evidenced.
- **A `PSI` zero means absent from a population topping out at 17.** Thin evidence. Every
  `PsiForecast*` row is a `PSI` row.

So "no unbound row has any corpus demand" holds **firmly for the Excel half and weakly for
the Psi half**. Quote it with the half it applies to.

### And "the 41-workbook corpus" is wrong

That phrase has been used in this repository and in session summaries. `SUM` alone appears in
338 workbooks. Forty-one was only ever how many workbooks carried Psi under one sweep, and it
is the denominator of nothing in the `EXCEL` half.

## Still open

- The `STDEV.S` book discrepancy, 79 against 42, inside the `EXCEL` half.
- Which Psi sweep is authoritative — the one behind the source comments, or the one behind
  this file's `PSI` rows.
- A third file version exists: the BusinessMath session's `excel_function_coverage_matrix_bak.tsv`
  counts one fewer row under each tag than this file. Same maxima, so it does not affect
  anything above, but the two are not identical and neither records its date.

## How to resolve it

Both sweeps need re-running from recorded roots, and the results labelled with which root
and which date produced them.

- `.excel-corpus` records the oracle root: `/Users/jpurnell/Documents`, which holds ~2,240
  `.xlsx` files. `BUSINESSMATHEXCEL_ORACLE=1` runs `ExcelOracleTests` against it;
  `BUSINESSMATHEXCEL_CORPUS` overrides with a colon-separated list.
- `RISK_SOLVER_WORKBOOKS` names the Risk Solver models directory and is **unset**, which is
  why `RiskSolverWorkbookTests` and `EndToEndSimulationTests` skip. Nothing records where
  that directory is.

**Cheapest first step, once `RISK_SOLVER_WORKBOOKS` is known:** check whether those models
are inside `/Users/jpurnell/Documents`. If any is not, the populations differ by
construction and no count is wrong. That is a membership test on a handful of filenames,
not a sweep.
