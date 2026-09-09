# What the `calls` and `books` columns mean — and why nobody currently knows

**Recorded 2026-09-09. Resolved the same day** — see §"The actual answer", which supersedes
everything between here and it. That section is short and the rest is kept only because it
was quoted onward while it was believed. Read it first.

## The actual answer: the `books` column is a **sheet** count

The generator was found by the BusinessMath session in a **third repository** —
`BusinessMathExcel`, `Tests/BusinessMathExcelTests/CorpusMeasurementTests.swift`,
`testWhichFunctionsTheCorpusCalls`. It loops over each workbook's sheets, incrementing
`callsByName` per call and `sheetsByName` once per sheet on which a name appears, and prints
`"\(calls) calls, \(sheets) sheets"`. **Both columns come out of the same loop over the same
files.** The matrix relabelled `sheets` as `books`.

That single relabelling generated every puzzle below:

- `SUM` 338 is 338 *sheets* across the 79 workbooks — about 4.3 per workbook.
- `STDEV.S` 42 against a comment's 79 is a sheet count against a workbook count. Two
  quantities, never in conflict.
- `EXCEL` 338 against `PSI` 17 is one sweep in which Psi appears on fewer sheets — not two
  populations, and not two denominators.
- The perfect zero-alignment is **structural**: the same loop writes both columns, so a
  function with no calls has no sheets by construction. The test built on it measured the
  shape of a `for` loop.

**What a `0 / 0` row therefore means**, plainly and without inference: *absent from every
formula on every sheet of the 79 workbooks swept.* The sweep parses each formula to an AST and
records every function name in it, so this is a well-defined negative over a named sample —
stronger than "not separately looked for" and weaker than "absent from 338 workbooks". Both of
those readings appear below; both are wrong.

**Not independently verified here.** `BusinessMathExcel` is not reachable from this machine's
Dropbox tree, so this rests on the BusinessMath session's quotation of the source. It explains
every observation in this document, which nothing else did. Citable, for whoever next has both
trees — in `BusinessMathExcel/Tests/BusinessMathExcelTests/CorpusMeasurementTests.swift`: the
test at **183**, the corpus gate at **59**, the sheet accumulator at **195–203**, the print at
**220**. One command to check rather than an afternoon to re-derive.

**When the sweep is next run:** rename the column to `sheets`; write the workbook count and
the date beside the data rather than in prose; and emit a workbook count as well — the outer
loop already computes it and discards it. `BUSINESSMATHEXCEL_CORPUS` gates that sweep;
`RISK_SOLVER_WORKBOOKS` is a different gate over a possibly different corpus and does not
regenerate this file.

---

*Everything below predates the answer above.*

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

### A zero is not a zero — and every zero in this file is one observation

**Superseded reading, kept because it was quoted:** that an `EXCEL` zero means "absent from a
population reaching 338 workbooks." It does not, and the test that killed it is one line.

Across all 815 rows: **no row has `calls > 0` with `books = 0`, and none has `calls = 0` with
`books > 0`.** The two columns agree perfectly on which 89 functions are non-zero. If the
`books` column really came from an independent sweep four times larger, it should have found
at least one function the smaller sweep missed. It found none — which means the `books` column
never searched the 726 candidates at `0 / 0`. Found by the BusinessMath session; confirmed
here.

So **every zero in this file rests on the 79-workbook call sweep**, and the defensible
statement is *"not observed in 79 workbooks, and not separately looked for in whatever
produced the book counts."* Not 338. And because it is the same 79 behind all of them, the
726 zeros are **one observation, not 726**.

Two explanations fit, and they differ in what a fix would cost:

- **Back-fill.** A larger sweep counted books only for functions the 79-workbook sweep had
  already found.
- **The column is sheets, not workbooks.** One sweep, one candidate list, a mislabelled
  column. `SUM` at 338 over 79 workbooks is 4.3 sheets per workbook, which is unremarkable,
  and it explains the perfect zero-alignment without needing two sweeps at all.

The second is correct — see the top of this document. My claim at the time, that the
provenance was "unreconstructable from this tree", was true of *this* tree and false as
stated: the generator lives in `BusinessMathExcel`, which this repository's own `README.md`
and `master_plan.md` both name. Neither session found it because each searched the repository
it was standing in.

**What this leaves for sequencing.** 79 workbooks is a real sample, and `COMPLEX`, all 25
`IM*` rows and all four `FORECAST.ETS*` rows are absent from it — that still says nobody in
that sample wrote them. It is one sample rather than an exhaustive search, and a `PSI` zero
remains weaker still, since that half undercounts the documented Psi sweep three to five
times over.

### There are three Psi measurements, and the matrix holds the weakest one

`PROPOSAL_psi_bindings.md` §2 documents a sweep **and its denominator**: "Measured across
2,236 workbooks: 27 distinct functions, 1,950 calls, 41 workbooks." That matches the ~2,240
`.xlsx` files under `.excel-corpus`'s root, so it is a sweep of the whole document tree.
Setting its table beside the other two:

| Function | Proposal (2,236 books swept) | Matrix `PSI` half | Binding doc comment |
|---|---|---|---|
| `PsiOutput` | 167 / 41 | 24 / 11 | 167 / 41 |
| `PsiMean` | 108 / 23 | 31 / 13 | 28 / 5 |
| `PsiPercentile` | 28 / 3 | 28 / 4 | 10 / 1 |
| `PsiStdDev` | 21 / 4 | 4 / 3 | 12 / 2 |
| `PsiTarget` | (tail, uncounted) | 5 / 2 | 7 / 3 |

Three populations, and the ordering is informative:

- **The proposal's sweep is the documented one** — it names its denominator and its date, and
  it is the only one of the three that does. Treat it as authoritative for Psi.
- **The matrix's `PSI` half understates it by three to five times** on every row that appears
  in both. It is a partial sweep of unrecorded provenance, which is a stronger statement than
  "a different population": it is demonstrably less complete than a measurement we have.
- **The binding doc comments are smaller again**, and their book counts — 5, 2, 1, 3 — are all
  within six. That is consistent with the six simulation models behind
  `RISK_SOLVER_WORKBOOKS`, which would make them correct about a deliberately small
  population. `PsiOutput`'s comment is the exception: 167/41 is quoted from the proposal, not
  measured over six. So that one file mixes two sources without saying so.

### And "the 41-workbook corpus" is a numerator, not a denominator

The phrase appears in this repository and in session summaries as though 41 were the corpus
size. It is not: **41 of 2,236 workbooks carry a Psi call**. `SUM` alone appears in 338
workbooks in the `EXCEL` half. Forty-one is a correct and well-sourced number that has been
quoted as the wrong kind of quantity.

### `STDEV.S` resolved: within the `EXCEL` half, `calls` and `books` come from different sweeps

`ReferenceFunctionTests.swift:13` states a denominator: *"Measured across 79 workbooks:
`COLUMN` 86,620 calls, `INDIRECT` 20,978, `OFFSET` 9,798, `ROW` 1,222."* Against this file:

| Function | 79-workbook sweep | Matrix `calls` | Matrix `books` |
|---|---|---|---|
| `COLUMN` | 86,620 | **86,620** | 45 |
| `OFFSET` | 9,798 | **9,798** | 32 |
| `ROW` | 1,222 | **1,222** | 2 |
| `INDIRECT` | 20,978 | 21,017 | 32 |

Three of four agree **exactly**, and the fourth is off by 39 calls in 21,000 — a re-run over a
near-identical set, not a different population. **So the `EXCEL` half's `calls` column is that
79-workbook sweep.**

Its `books` column cannot be. `SUM` reports 338 books, `IF` 239, `SUMPRODUCT` 134 — you cannot
observe a function in 338 workbooks having read 79. **The two columns of the same row were
produced by different sweeps**, and no row's `calls`/`books` pair is internally consistent.

That closes `STDEV.S` with no error in it anywhere: 86,410 calls from the 79-workbook sweep,
42 books from the larger one. The source comment's *"86,410 times across 79 workbooks"* names
the sweep it came from, phrased so that the denominator reads as a book count. Nothing
disagreed; the sentence was ambiguous and both halves of this file were quoted as one.

## Still open

- What the `EXCEL` half's `books` column counts, and whether it ever looked for the 726
  functions at `0 / 0` — the evidence says it did not. (The `calls` column is settled: the
  79-workbook sweep.) **A re-measure of the books column alone would not change a single
  zero**; what is needed is a fresh sweep over the full candidate list on a named denominator.
- Why the matrix's `PSI` half is three to five times smaller than the documented sweep in
  `PROPOSAL_psi_bindings.md` §2, given both claim to read the same kind of thing. The
  proposal's is authoritative; what the matrix's is remains unknown.
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
