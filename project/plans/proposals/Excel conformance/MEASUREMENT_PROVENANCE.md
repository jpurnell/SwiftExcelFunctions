# What the `calls` and `books` columns mean — and why nobody currently knows

**Recorded 2026-09-09.** Unresolved. Read this before using
`excel_function_coverage_matrix.tsv`'s counts to argue for anything.

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
