# Changelog

All notable changes to SwiftExcelFunctions will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Every row of the coverage matrix is classified.** The `PSI` bucket went from 147
  unreviewed to **zero**: 189 have, 71 out of scope with a written reason each, 17 bindable,
  17 not ours, 1 new. The `EXCEL` bucket closed on 2026-09-17, so nothing in the file is
  unreviewed for the first time.

  `UnreviewedCoverageTests` now watches **every source**. It filtered to `EXCEL` because the
  147 `PSI` rows would have failed its assertion — a guard scoped around a gap it could see,
  which is how a fixture rots. The scope is off.

  Implemented along the way: 16 run statistics, 17 theoretical statistics, 20 Six Sigma
  metrics plus `PsiSixSigma`, 8 property functions, and 10 further statistics including the
  two that need two runs at once.

- **`ISOMITTED` was marked out of scope**, with the recorded reason *"there is no LAMBDA"*.
  LAMBDA shipped in the previous session and `ISOMITTED` with it; the row never moved. EXCEL
  reads 495 have, 24 out of scope. A classification that encodes a temporary gap rots exactly
  as a fixture does.

### Fixed

- **A Solver model naming a whole column tried to enumerate 1,048,576 cells.**
  `ExcelSolverReader` turns a model's references into one `CellRef` each — about 25 MB for a
  model that cannot use them, since Excel's own Solver caps decision variables at 200.

  **This was already reachable before today**, by the defined-name path:
  `DefinedNameResolver` has always read `Sheet1!$A:$A` as the whole column it is. Fixing
  `CellRange(_:)` in SwiftExcelCore 0.14.0 added a second way in — a literal `A:A` in a
  multi-area reference string — which is what made it worth looking at.

  An area larger than `maximumModelCells` (4,096, the bound
  `DependencyGraph.exactEnumerationLimit` already uses for the same reason) now names **no**
  cells. **Refused rather than truncated**: half a model is worse than none, because a caller
  handed the first 4,096 cells of a column has something that looks complete and optimises the
  wrong thing. Areas beside an oversized one are kept.

- Dependency floors: SwiftExcelCore **0.14.0**, SwiftXLSX **0.31.1** — where `A:A` and `1:1`
  stop being read as `A1` and as a range in column zero.

### Added

- **Array constants evaluate: `{1,2,3;4,5,6}`.** Core Excel syntax this package could not read
  at all — parsed in SwiftXLSX 0.31.0 against `FormulaAST.arrayConstant` from SwiftExcelCore
  0.13.0, and turned into a `CellMatrix` here. Every function that already takes an array now
  takes one written in the formula: `SUM({1,2,3})`, `SUMPRODUCT({1,2},{3,4})`,
  `INDEX({1,2;3,4},2,1)`, `ROWS`/`COLUMNS`, the lot.

  An error element is a **value**, not a failure to build the array, so it behaves like an
  error cell would: `COUNT({1,#N/A,3})` is 2 because `COUNT` counts numbers, and
  `SUM({1,#N/A,3})` is `#N/A` because summing an error is an error. Both follow from the
  element being an ordinary `CellValue` rather than from a rule written for arrays.

  **Refused by the `Lowerer`**, which compiles scalar bytecode for the solver. `SUM({1,2,3})`
  could in principle fold to a constant, but folding *some* array constants and refusing the
  rest would make which models compile depend on where the array sits — worse than refusing
  all of them plainly, which is what a range outside an aggregate already gets.

  This was found from the side: `ReferenceShapeTests` wanted a two-row array to check that
  `ROWS` still counts an array from its values, and could not spell one. That test now spells
  it, and keeps the `SEQUENCE(2,3)` form beside it, since the two reach an array by different
  paths.

### Verified

- **Round nine came back with zero disagreements across all 158 cases** — the first round in
  this project's life to do so. It confirmed the `ROWS(A:A)` and `COLUMNS(1:1)` fixes below
  against Excel, and settled the one density boundary still resting on an inference:
  `BETA.DIST`'s upper endpoint below a shape of one, which had been applied by symmetry with
  its lower endpoint. **The inference held** — Excel refuses at or below a shape of one and
  answers zero above it, so `BETA.DIST(1, 2, 1, FALSE)` is `#NUM!` where the density is an
  ordinary 2.

  The reasoning is kept rather than deleted now that it came out right. Being correct is not
  the same as being entitled to guess: `GAMMA.DIST` and `WEIBULL.DIST` face the identical
  boundary and disagree with each other, so the symmetry that held here was a coin that landed
  the right way up. **No density boundary in this package now rests on an inference.**

### Fixed

- **`ROWS(A:A)` answered the height of the used range, not 1,048,576.** Ten on a sheet with
  ten rows of data; zero on an empty one. Excel answers 1,048,576 on every sheet, whatever is
  in the column.

  Not a wrong formula — a consequence of a decision that is right everywhere else.
  `CellRange.clipped(to:)` pulls a whole-column reference back to the used range, because
  `$B:$B` in a real workbook means "whatever is in column B" and the alternative is
  materialising a million values per reference. Every function that *reads* those values wants
  the clipped range. `ROWS` and `COLUMNS` do not read them — they count positions, and a
  position exists whether or not anything was typed into it.

  `CellRange` had already worked out half of this: it keeps a whole **row** at its full 16,384
  columns and gives the reason — *"`INDEX`, `COLUMNS`, `ROWS` and the lookups all count
  positions"* — while clipping a whole column, where the same argument applies. New
  `ReferenceShape` answers both from the reference as written, before it resolves to values. A
  defined name pointing at a whole column counts like one; array literals and computed
  references (`OFFSET`, `INDIRECT`) fall through to the ordinary path, which is right for them.

  **This had been dismissed as a harness artifact** — the conformance row was assumed to fail
  because the tool evaluates against `NoCells()`. It fails on a populated sheet too. Checking
  that took one probe, and was not done for seven rounds.

- **`COLUMNS(1:1)` could not be parsed, so it could never be asked.** Fixed upstream in
  SwiftXLSX 0.30.0, where the whole-row branch existed and was unreachable — it sat below the
  plain `.number` case in `parsePrimary`, and `1:1` lexes as a number. The `$3:$3` form was
  unaffected, which is why the shorthand's failure read as a missing feature rather than a
  defect. This package now pins 0.30.0.

### Changed

- **`conformance-workbook check` matches rows by formula, and compares against a live
  evaluation.** It used to walk `ConformanceCases.all` and index the sheet by position, which
  made the tool's own claim — *"no manifest, no ordering assumption, nothing to fall out of
  step"* — untrue. The formula was in column B the whole time, written by `emit` and never
  read. Appending a round was harmless; inserting a case anywhere else would have compared
  Excel's answer for one formula against this package's answer for another, and reported
  agreement or disagreement that meant nothing.

  Column D — this package's answer at emit time — is still written and still reported, as
  provenance. It is no longer the comparison: `check` re-evaluates each formula, so **a fix is
  verifiable against the same workbook** instead of needing a fresh round in Excel. That was
  the position after round eight: seven conventions corrected, and no way to confirm them
  without asking a person to open a spreadsheet again. Rows whose answer has changed since
  emit are reported as `CHANGED`, and cases the workbook predates as `NOT ASKED` — which
  points at `emit`, where the old wording ("not calculated") pointed at Excel.

### Fixed

- **Five functions answered the density at a support boundary five different ways, and
  Excel was never asked.** Round eight of the conformance workbook asked it. Seven of
  twenty-three rows came back disagreeing, and Excel turns out to use **three different
  conventions** across the family, none derivable from another:

  | | shape < 1 | shape = 1 | shape > 1 |
  |---|---|---|---|
  | `CHISQ.DIST` | `#NUM!` | ½ — the density | 0 |
  | `GAMMA.DIST` | `#NUM!` | `#NUM!` — where the density is `1/β` | 0 |
  | `BETA.DIST` | `#NUM!` | `#NUM!` — where the density is 5 | 0 |
  | `WEIBULL.DIST` | **0** | **0** | 0 |
  | `F.DIST` | `#NUM!` | **1** — the density | 0 |

  `F.DIST(0, 1, 5, FALSE)` answered 0 where Excel answers `#NUM!`, and
  `F.DIST(0, 2, 5, FALSE)` answered 0 where Excel answers exactly 1. `GAMMA.DIST` answered
  `1/β` at a shape of one where Excel refuses. `BETA.DIST` refused both endpoints
  unconditionally where Excel answers zero above a shape of one. `WEIBULL.DIST` is a flat
  zero at x = 0 for every shape — including where the density is unbounded.

- **`GAMMA.DIST` and `WEIBULL.DIST` returned `+∞` as a number** at a shape below one. The
  density there genuinely is unbounded, so the mathematics was right and the
  *representation* was not: no cell can hold an infinity, and the value reaches
  `sheet.write(_:to:)` in any workbook this evaluator feeds. SwiftXLSX has already killed a
  corpus run once on a value it could not represent — a number past `Int.max`, fixed in
  0.26.1. **This is the one part of the boundary question that never needed Excel**, and it
  is now a test in its own right: nothing answered as a density may be non-finite.

  Worth recording how the rest went: the guess that replaced `+∞` was `#NUM!`, by analogy
  with `CHISQ.DIST`. It was right for `GAMMA.DIST` and **wrong for `WEIBULL.DIST`**.
  Analogy between two Excel functions is not evidence about either.

### Changed

- **BusinessMath 3.0.0-alpha.6 → 3.0.0-alpha.7**, which required no `Package.swift` edit: the
  `.upToNextMinor(from: "3.0.0-alpha.3")` range already admitted it, as the note beside that
  line predicted. The bump takes 29 upstream commits — branch-and-bound determinism, two
  bytecode miscompilations, a false optimality certificate, simulated annealing, constrained
  optimisation, and two numerical finite-difference defects. All 1,691 existing tests pass
  across it unchanged.

- **Seven densities stop keeping their own copy of the mathematics.** `EXPON.DIST`,
  `GAMMA.DIST`, `LOGNORM.DIST`, `BETA.DIST`, `WEIBULL.DIST`, `CHISQ.DIST` and `F.DIST` each
  wrote out a closed-form density when their `cumulative` flag was `FALSE`, because
  `ContinuousDistribution` had no `pdf(_:)` to bind. alpha.7 adds one, and they now delegate.

  **No Excel-visible behaviour changes.** Every domain rule stays in this package: the `#NUM!`
  at a chi-squared's unbounded point, `BETA.DIST` refusing both endpoints, `F.DIST` answering
  zero at zero for every numerator. Upstream answers `infinity` in the first and third of
  those — correctly, because that is the density — and the mapping onto `#NUM!` or zero is a
  spreadsheet convention rather than a fact about the distribution.

  `WEIBULL.DIST` was the sharpest case: it already constructed a `DistributionWeibull` for its
  cumulative branch and hand-wrote the density two lines below it. One function, two opinions.

### Added

- **`DensityBindingTests`** — the seven densities pinned to **the numerical derivative of their
  own cumulative branches**, plus quadrature, the boundary conventions above, and `BETA.DIST`'s
  `A`/`B` Jacobian. Written and run **against the hand-rolled code first**, so that "still
  green" after the rebinding says something; then checked by deliberately breaking two things a
  rebinding plausibly breaks — Excel's gamma `beta` read as a rate rather than a scale, and
  `BETA.DIST`'s width Jacobian dropped — which produced 9 failures across 4 of the 5 tests.

  That last check is the reason the file exists. A delegation is where a **parameterisation**
  slips without anything failing to compile, and all three candidates here are silent:
  `GAMMA.DIST`'s scale-versus-rate, `LOGNORM.DIST`'s parameters being of `ln(x)`, and
  `BETA.DIST`'s bounds carrying a Jacobian that a unit-interval test could never detect.

### Removed

- **A private `logGamma`**, whose own documentation said "the F density needs it". It did, and
  the F density is no longer written here. Found by the gate rather than by reading — a
  de-duplication removes the reason a helper existed, and nothing in the build notices.

## [0.11.0] - 2026-09-18

### Added

- **Every function Microsoft documents is now implemented or out of scope with a reason.**
  494 `have`, 25 out of scope; nothing unreviewed and nothing merely classified.

  The last 21 were a backlog marked `bindable` — known, unimplemented, mathematics available —
  that predated this work and was never part of the unreviewed bucket. That distinction is how
  "every row classified" and "every row implemented" came apart in a status line, and the
  README said the wrong one for a few hours. `FACT`, `COMBIN`, `MMULT`, `MINVERSE`, `SEQUENCE`,
  `SUMXMY2`, `DAYS360`, `MIRR`, `XNPV`, `CUMIPMT`, `CUMPRINC`, `DDB`, `RRI`, `PDURATION`,
  `CHISQ.DIST`, `T.DIST`, `F.DIST`, `LINEST`, `LOGEST`, `TREND` and `GROWTH`.

  `SEQUENCE` is worth a line of its own: the conformance workbook's `REDUCE` control writes
  `REDUCE(0, SEQUENCE(8192), …)`, so until now this package could not evaluate the very formula
  it uses to ask Excel a question.

- **`LAMBDA`, whole.** All six steps of `PROPOSAL_lambda.md`, plus a prerequisite it did not
  have. `LET`, named and immediately-invoked lambdas, recursion, `ISOMITTED`, and the
  higher-order six — `MAP`, `REDUCE`, `SCAN`, `BYROW`, `BYCOL`, `MAKEARRAY`.

  Two source-breaking changes in SwiftExcelCore, taken deliberately at minor versions and
  after the measured demand had shipped without them: **`CellValue.lambda`** with
  **`ExcelError.calc`** (0.11.0), and **`FormulaAST.call`** for the immediately-invoked form
  (0.12.0). A lambda that is *returned* by a lambda, *bound* by a `LET` or *chosen* by an `IF`
  is legal Excel and inexpressible without them, and each would otherwise evaluate to
  something plausible rather than to an error.

- **The unreviewed bucket reached zero.** 87 `EXCEL` rows classified: **473 have, 25 out of
  scope with a written reason each, 20 bindable.** Seventy-three of the 87 were implemented
  rather than merely classified.

  - `logical` — `IFS`, `SWITCH`, `XOR`, and the eight that arrived with `LAMBDA`
  - `math` — the rounding family, Roman numerals, `MDETERM`, `MUNIT`, `AGGREGATE` and the rest
  - `database` — all twelve `D` functions, from one criteria-range design shared with `SUMIF`
  - `lookup` — sixteen dynamic-array functions; eight out of scope, see
    `project/docs/technical/LookupOutOfScope.md`
  - `financial` — twenty-one, including the four `ODD*` bonds and their quasi-coupon periods

  Recorded beside it: **all 87 had zero corpus usage.** The census columns are populated, so
  that is a measurement rather than missing data, and the case for the work was completeness
  rather than demand.

### Fixed

- **A branch not taken is now a branch not evaluated.** The evaluator evaluated *every*
  argument before dispatching, which is right for `SUM` and wrong for `IF`. The difference is
  invisible for errors — an unchosen `1/0` becomes `#DIV/0!` and is discarded — and fatal for
  recursion, which does not become an error value but runs. **No recursive `LAMBDA` could have
  terminated until this was fixed.** `IF`, `IFERROR`, `IFNA`, `CHOOSE`, `IFS` and `SWITCH` are
  now reached before their arguments; `AND`, `OR` and `XOR` stay eager, because Excel does not
  short-circuit them either.

- **Two counters where Excel has two, and a stack bound that holds.** `maxDepth = 256`,
  incremented per AST node, was wrong three ways against the conformance measurements: an
  order of magnitude off, counting the wrong thing, and conflating two budgets Excel keeps
  apart. Now `maxCallDepth` (65 function calls), `maxRecursionDepth` (4,096 invocations) and
  `maxNodeDepth` (512, this evaluator's stack guard and not a claim about Excel).

  Operators are not calls: a 300-term sum is one expression, and at 256 nodes the evaluator
  refused something Excel computes without complaint.

- **`LAMBDA` arity is exact** — conformance round 6, which reversed an assumption this
  evaluator had been built on. A lambda may not be called with fewer arguments than it
  declares; an empty argument *position* is a different thing, and is what `ISOMITTED` reports
  on. A named lambda obeys the same rule.

- **`ERROR.TYPE` of `#CALC!` is 14, measured.** It was the last value in that function taken
  on Microsoft's published word.


### Added

- **A workbook keeps its defined names** — SwiftXLSX 0.26.0 and SwiftExcelCore 0.10.0.

  The reader parsed every `<definedName>`; the writer emitted none, so a file read by this
  family and written back came out with an **empty Name Manager** and nothing said so.
  Measured across 2,240 workbooks: **1,022 define names, 161,901 in all**, 46% of them hidden,
  and the largest single model carries 47,106.

  The design is **one representation**: a name is held once, its target *is* its meaning, and
  the writer derives the refers-to text from that target rather than keeping the file's string
  beside it. Two copies of one fact drift the moment anything changes one of them — and drift
  here means silently writing the *old* reference into somebody's workbook.

  That needs a target able to say everything a name can be, so `NamedRangeTarget` gains
  **`.unparsed(String)`**. The old fallback, `.formula(.text(raw))`, kept the characters and
  claimed the name **was a text constant** — written back it gains quotes, so a range becomes
  a caption and a number becomes a string.

  `.unparsed` round-trips by the identity function, which is what makes reconstruction safe
  rather than ambitious: byte-exactness is available for every name from the start, and each
  shape the reader parses is an opt-in promise with a test behind it.

- **`name-round-trip`** — the measurement that licenses that choice. Reads a corpus, writes
  each workbook back, reads it again, and compares the name tables. Reconstruction has to be
  right every time; the reason to accept that cost is that being right is *checkable*, where
  drift is a future mutation no test can enumerate.

### Fixed

- **A whole-column name is a reference again, and `SUMIFS` over one works.** The same defect
  seen from the other end: SwiftXLSX's `isReference` wanted a letter *and* a digit in each
  half, so `$D` failed and `amounts = Expenditures!$D:$D` was read as not-a-range. The
  evaluator then summed the name's own text — `SUMIFS(amounts, …)` answered **zero across
  1,058 cells** in one corpus workbook, with no error anywhere to say why.

- **A name this package cannot read answers `#NAME?`.** It exists in the file and we do not
  know what it points at, which is what `#NAME?` says. A refusal is visible; a plausible zero
  is not.

- **`WorkbookOracle` asks instead of inferring.** Telling "could not read this" from "this is
  a text constant" used to mean looking for a `!` and the absence of a quote. The reader says
  which it is now.

- **Two hand-built fixtures encoded the reader's old failure mode** — `ExcelSolverReaderTests`
  and `StaleValueCheckerTests` both constructed `.formula(.text(…))` targets by hand. They
  agreed with the code about something neither had checked against a file, which is the fifth
  time this project has hit that trap. Both corrected.


- **`conformance-workbook depth` — asking Excel where its own limits are.** Microsoft
  documents 64 levels of function nesting and says nothing whatever about `LAMBDA`
  recursion, so the only authority is Excel. Four sections: expression nesting, recursive
  `LAMBDA` with a thin body, the same with a fat one, and `REDUCE` iteration. Thin against
  fat is the one that decides the implementation — both failing at the same depth means the
  budget is counted in calls, the fat one failing earlier means it is stack.

  **First answer: 65 nested calls load and 66 do not.** Excel replied by refusing to open
  the file — `Removed Records: Formula from /xl/worksheets/sheet1.xml` — and stripping
  exactly the four cells above 65, leaving the rest of the sheet untouched. So the limit is
  enforced **when the file loads, not when the formula runs**: an over-nested formula is not
  an error value, it is a workbook Excel repairs by deleting the cell.

- **The `text` and `information` categories, closed.** Twenty rows out of the unreviewed
  bucket: fifteen implemented and five marked out of scope with the reason written down.

  | | |
  |---|---|
  | `ISEVEN`, `ISODD` | parity, **truncated** toward zero — `ISEVEN(2.9)` is TRUE |
  | `ISLOGICAL`, `ISNONTEXT` | the remaining kind predicates |
  | `N` | Excel's coercion table, where `N("7")` is **0** and not 7 |
  | `TYPE`, `ERROR.TYPE` | the kind and the error, as numbers to branch on |
  | `ISFORMULA` | the only one that reads the *cell*: a formula returning 7 and a typed 7 are the same value and different cells |
  | `DOLLAR` | currency text, negatives in parentheses, negative places rounding left |
  | `VALUETOTEXT`, `ARRAYTOTEXT` | concise for a person, strict for a formula to read back |
  | `TEXTSPLIT` | text into a rectangle, rows the outer cut, ragged rows padded with `#N/A` |
  | `REGEXTEST`, `REGEXEXTRACT`, `REGEXREPLACE` | the 2024 trio, over `NSRegularExpression` |

  **Out of scope, each for its own reason:** `INFO` reports the machine it runs on;
  `STOCKHISTORY` calls a web service; `SHEET` and `SHEETS` need the workbook's sheet list,
  which an evaluator handed a `CellValueProvider` does not have; `ISOMITTED` asks whether a
  `LAMBDA` argument was supplied, and there is no `LAMBDA` yet. Recorded in the matrix
  rather than left unreviewed, because "we decided not to" and "nobody looked" are different
  states and only one of them is finished.

  **Measured: `have` 379 → 394, `unreviewed` 107 → 87, `out of scope` 12 → 17.** The
  remaining 87 are lookup 24, financial 21, math 19, database 12 and logical 11.

- **`xlsx-audit` — the checks, runnable by someone who is not us.**

  ```
  swift run xlsx-audit Model.xlsx
  swift run xlsx-audit ~/models --experimental --tsv findings.tsv
  ```

  Exit `0` clean, `1` at least one error finding, `2` nothing could be read — so CI can gate
  on it. A warning or a note does not fail the run: those are for a person to judge, and a
  check that fails a build on a judgement call is a check that gets switched off.

  `--only NAME` runs a single checker, which is what a false-positive census needs; `--tsv`
  is written **as the run goes** rather than at the end, because this project has three
  times killed a long corpus run that had produced nothing.

- **`stale-value` — the check nobody else can make.** Excel caches the result of every
  formula cell, so a saved workbook carries both a program and its claimed output. Recompute
  the program from the file's own inputs and a disagreement means the number on the screen
  does not follow from the formula beside it: calculation left on manual, a formula edited
  and never recalculated, a value pasted over a result.

  **It finds the origin, not the cascade.** Each formula is judged against Excel's cached
  inputs rather than our recomputation of them, so a stale cell does not poison its
  dependents — they agree with their own caches and stay silent. One stale edit is one
  finding, at the cell that was edited.

  The honesty rule is most of the implementation: a disagreement is reported only where *we*
  are right. Refusals and throws are ours by definition; twelve function names are excluded
  by name with a citation each — the Bessel family and `IMSQRT`/`IMPOWER`, where Excel is
  the imprecise party against SciPy and against definitions, and `YEARFRAC` and the four
  bond functions that share its day count, where **we** are. `Skipped` counts what was
  passed over and on whose account, so the silence is auditable.

### Fixed

- **Excel's operators apply to rectangles, and did not.**

  `A1:A10*2` is ten products; `--(area=$C4)` is ten ones and zeros. Every binary operator
  coerced a rectangle to a single number instead, so a comparison against a range collapsed
  to one `FALSE` and the commonest conditional-count idiom in spreadsheets —

  ```
  SUMPRODUCT(--(LEN(steps)>1), --(area=$C4), --(dates>=S$3), --(dates<=EOMONTH(S$3,0)))
  ```

  — answered `0` while looking entirely healthy. Unary negation had the same gap, which is
  the other half of `--(…)`.

  Now: the result is as tall as the taller operand and as wide as the wider one, a single
  row is reused down the rectangle and a single column across it — so **a row against a
  column is a matrix**, which is Excel's answer and surprises most people once — and where
  a side does not reach, the element is `#N/A` rather than clipped or repeated.

  **Measured: 583 cells in one workbook**, all answering zero.

- **The oracle reads a workbook once.** `WorkbookValueProvider.value(at:)` finds its sheet by
  scanning `workbook.sheets` and comparing names, on *every cell read*. One
  `SUMIFS($F$2:$F$20001, $E$2:$E$20001, …)` reads 80,000 cells, and a sheet of them reads
  tens of millions — each paying a linear scan over thirteen sheet names and a retain of the
  cell's style.

  The oracle now snapshots every cell into a dictionary keyed by position, and caches the
  rectangles it materialises: a column of 20,000 formulas naming the same four ranges reads
  those ranges once rather than 20,000 times. Measured on the workbook that made this
  visible: **over 7 minutes to 3.9 minutes**, and it is the criteria matching that is left.

  The key is a position rather than a reference string. Keying by `"$B$1"` meant building
  that string on every read, and the profile was almost entirely integer-to-ASCII.

- **A cell holding a formula is never blank**, whatever the formula produced.

  `IF(…, A3, "")` leaves `<c t="str"><f>…</f><v/></c>` — a formula whose result is the empty
  string. `ISBLANK` of it is FALSE in Excel, because there is a formula in there. It read as
  blank here, so `IF(NOT(ISBLANK(G3)),1,0)` answered 0 where Excel cached 1: **147 cells in
  one workbook.**

  The reader cannot distinguish an empty `<v/>` from a missing `<v>`, so the rule is applied
  where a reference is read rather than where the file is parsed.

- **`*` and `?` in a criterion.** `COUNTIFS(volunteers, "*")` cached 38 and answered 0,
  because the criterion was compared as the literal text. Excel's two wildcards and the
  tilde that escapes them now work across the whole criteria family — `COUNTIF`, `SUMIF(S)`,
  `AVERAGEIF(S)`, `MAXIFS`, `MINIFS` — with the three rules that are easy to get wrong:
  only equality reads them, they match **text** so `"*"` passes over the numbers, and the
  match is anchored at both ends.

- **`TEXT(0, "####")` is the empty string**, and `TEXT(5, "0000")` is `"0005"`. `#` means "a
  digit if there is one" and `0` means "a digit, or a zero"; the difference shows only at
  zero, and at zero it is the difference between `", )"` and `", 0)"` in a heading somebody
  reads.

- **`IPMT` and `PPMT` had swapped places.** A positive present value is money owed, so both
  parts of a payment are negative — Microsoft's own example says `IPMT(0.1/12, 1, 3*12,
  8000)` is −66.67, which is exactly −(8000 × 0.1/12). The sign was inverted, so the
  interest came back as the principal and the principal as the interest.

  **Every test used a negative `pv`**, where an inverted answer looks entirely plausible,
  and the two inversions cancel in `IPMT + PPMT = PMT` — so the identity test beside it
  passed throughout. A mortgage schedule in a real file cached −492.61 for a `PPMT` where
  this answered −7807.61: **720 cells.**

  Also rewritten as a closed form. The balance after *k* payments is `pv(1+r)^k + pmt·s(k)`;
  the loop that accumulated it was `O(per)` for an answer that is `O(1)`.

- **An empty cell is both `0` and `""`.** Excel answers TRUE to `A1=0` and to `A1=""` for
  the same empty `A1`, which no single normalisation can do — mapping blank to `0` made
  `A1=""` a number against a text, and therefore FALSE. Which one a blank reads as now
  depends on what it is compared against.

  `IF(AND(E20="",G20="No"),1,2)` is how a spreadsheet asks "has this been filled in yet".

- **A date concatenates as its serial**, because that is what a date is in Excel. An ISO
  string made `">=" & I4` a criterion no date could match, so
  `SUMIFS(amounts, dates, ">="&I$4, …)` summed nothing while looking right. A date *criterion*
  reads the same way — `SUMIFS(amounts, month, I$1, …)` had been refusing the whole call.

- **`TEXT(0, "yyyy-mm-dd")` is `"1900-01-00"`** — a day that does not exist, which Excel
  shows anyway. It is what an empty cell formatted as a date renders as, and a template full
  of unfilled date cells produces it by the hundred: 176 cells in one workbook built a JSON
  string out of one.

- **`INDEX` reads 0 and an omitted argument as "all of them"**, which is what Microsoft
  documents. `IFERROR("C"&INDEX(MATCH(F5,C:C,0),,1),"")` was refused and fell through to its
  `IFERROR` — 119 cells answering `""` where Excel answered `"C50"`. A test asserting the
  old refusal is reversed, with the reasoning it encoded kept beside the rule that replaced
  it.

- **Five more, found by widening the census from 38 workbooks to 488.**

  - **Excel's comparison rule applies wherever Excel compares** — a criterion included.
    `COUNTIF(H2:H23, "1")` counts `0.99999999999999978` as a 1, because the difference is
    negligible against the operands: the same rule that makes `0.1+0.2=0.3` true. Comparing
    the raw doubles answered 6 where Excel answered 11.
  - **A number becomes text at fifteen significant digits.** `"Donations: " & SUM(D2:D389)`
    answered `"Donations: 1052.949999999999"` where Excel writes `"Donations: 1052.95"` — a
    `Double` carries seventeen digits and Excel shows fifteen. This is Excel *displaying* a
    number rather than *storing* one, which is the distinction ADR-003 turns on.
  - **Arithmetic that leaves the reals is `#NUM!`**, not infinity. A spreadsheet has no way
    to show an infinity and every function downstream would have to invent an answer for it.
  - **`SUMPRODUCT` propagates an error** rather than dropping the term. Text and blanks
    contribute zero so their term falls out; `#N/A` makes the whole sum `#N/A`, which is
    what stops a total quietly reading low because one input is missing.
  - **Implicit intersection is not modelled, so it is not judged.** `=annRevenue - annCost`
    where those names span fifteen columns is, in Excel's pre-dynamic-array semantics, the
    one column that lines up with the formula's own position; this package returns the whole
    row, because the alignment needs the array's origin on the sheet and a `CellMatrix` does
    not carry one. Comparing the first element instead would be right one time in fifteen —
    214 cells in one sweep — so the oracle declines to compare them at all.

- **Two reading rules in the oracle, so the checker does not accuse a workbook of our gaps.**

  **A line break is stored two ways in the same file** — a newline in the shared-string
  table, `_x000D_` in a formula's cached value — so `=D21` appeared to disagree with itself.
  Both are read as a newline now.

  **A whole-column defined name does not resolve.** `amounts = Expenditures!$D:$D` comes
  back as unparsed text, because the reader's reference test wants a letter *and* a digit in
  each half and `$D` has no digit. The name then evaluates to its own text and
  `SUMIFS(amounts, …)` sums nothing — **1,058 cells in one workbook.** The parser is
  upstream in SwiftXLSX and a second one here is what the package split exists to prevent,
  so the defect is recorded and the oracle declines to *judge* a formula it knowingly cannot
  evaluate. A cell we cannot compare is not a cell that disagrees.

### Changed

- **`AuditModel.graph` is built when a checker asks for it, not before.** The dependency
  graph is the expensive part of assembling a model, and `stale-value` needs none of it —
  it judges each formula against cached inputs, so there is no precedent order to compute.
  Measured on 38 real workbooks: **2 minutes 30 → 7.8 seconds.**

  **Every fix above was found by the checker's own census**, not by a test. Its first run
  reported 559 findings across 38 workbooks and all 559 were ours; widened to four corpora
  it found another ten classes, and all of those were ours too. A checker whose first
  findings are its own author's bugs is still a good checker — it is a test suite that
  writes its own cases from real files. What it must never do is report them as somebody
  else's.

  **The number it ships on: 488 workbooks, 486 clean, 2 findings.** One is an `NPV` that
  differs in the fourth significant figure and has not been attributed to either side; the
  other is a genuine one. Getting there took fifteen fixes to this package and five reading
  rules in the oracle, which is the census doing its job.

  `stale-value` ships **opt-in** (`--experimental`) rather than enabled, for the reason
  `PROPOSAL_workbook_validator.md` §9 gives: a checker needs a false-positive number before
  it earns a default, and the number it has so far is *zero findings on the corpora it has
  been triaged against* — which is not the same as zero false positives on a corpus nobody
  has looked at.


- **Twenty-nine functions, chosen by what the corpus actually calls.**

  A sweep of **2,236 workbooks** asked one question — which function names does this
  package fail to answer — and the answer was **eighteen names**, not the 115 the coverage
  matrix carried as unreviewed. The two lists barely overlap, and the measurement reordered
  the work:

  | Name | Calls | Books | What it needed |
  |---|---|---|---|
  | `RANDOMNORMAL` | 10,801 | 1 | **a user-defined `LAMBDA`** — see the correction below |
  | **`WEEKNUM`** | 209 | 1 | a build |
  | **`AVERAGEIFS`** | 35 | 1 | a build |
  | **`NETWORKDAYS`** | 12 | 3 | a build |
  | **`SUBTOTAL`** | 8 | 1 | a build |
  | **`SKEW`** | 7 | 3 | a binding |
  | **`CORREL`** | 2 | 1 | a binding |
  | `YIELDMAT`, `YIELDDISC` | 3 | 2 | financial, still open |
  | **`MODE`, `FORECAST`, `RSQ`** | 1 each | 1 | a binding, or an alias |
  | `LINEST` | 1 | 1 | array-shaped, still open |
  | `BS`, `MYLAMBDA`, `MAXEXP`, `CALLOPTION` | 1 each | 1 | two are `LAMBDA`s, two are macros |

  **Every statistical name on that list was already implemented upstream**, under a name no
  search for the Excel spelling would reach — `skewS`, `correlationCoefficient`, `rSquared`.
  `MODE` and `GAMMALN` were already implemented *here*, under `MODE.SNGL` and
  `GAMMALN.PRECISE`, and were answering `#NAME?` for the sake of a full stop.

  What landed:

  - **The working-day family.** `NETWORKDAYS`, `NETWORKDAYS.INTL` and `WORKDAY.INTL` join
    the `WORKDAY` that was already here. The weekend argument has two spellings and they
    are not interchangeable — a **code** from Excel's own dialog, or a seven-character
    **mask** reading Monday first, where `1` marks a day that does *not* work. `"0000011"`
    reads as the number 11 if given the chance, turning "Saturday and Sunday" into "Sunday
    only" — a plausible answer four days in seven — so the argument's *type* decides which
    spelling it is, never what it looks like.

    Checked against `numpy.busday_count` and `busday_offset` across all fourteen weekend
    codes, over a month that starts on a Tuesday so that an off-by-one mapping cannot hide.

  - **`WEEKNUM`, `ISOWEEKNUM`, `DATEDIF`, `TIMEVALUE`.** `WEEKNUM` numbers the week ten
    ways and `ISOWEEKNUM` the one way that is a standard: 1 January 2016 is week 1 to the
    first and week 53 *of 2015* to the second, which is a difference of a year rather than
    of a week. ISO weeks were checked against Python's `date.isocalendar()`.

    **`DATEDIF`'s `"MD"` unit reproduces Excel's own wrong answer**, deliberately.
    `DATEDIF("2016-01-31", "2016-03-01", "MD")` is −1 in Excel, because the borrow is
    February's 29 days against a gap of 30, and Microsoft's reference calls the unit "not
    recommended" for exactly that reason. ADR-001 makes Excel the specification; fixing it
    here would put us in disagreement with the sheet in the one unit its own vendor warns
    about.

  - **`AVERAGEIFS`.** The value range comes first — `SUMIFS`'s order, *not* `AVERAGEIF`'s,
    where the criteria range leads. Reading the two alike averages the wrong column without
    erroring. No matching row is `#DIV/0!`, where `MAXIFS` on the same shape answers zero:
    there is no consistent rule across the `*IFS` family to infer, only what Excel
    documents for each.

  - **`SUBTOTAL`.** Eleven aggregates behind one number, in two blocks. **The 101–111 block
    answers exactly what 1–11 answers**, and that is stated rather than hidden: the
    hundreds ignore rows the user hid by hand, row visibility is a property of the *sheet*,
    and an evaluator handed `[CellValue]` has no way to ask. The nesting rule — a
    `SUBTOTAL` skips other `SUBTOTAL`s inside its range — needs the cells' *formulas* and
    is likewise not modelled. A test pins both, so they are decisions rather than
    oversights.

  - **Eighteen statistical bindings**: `SKEW`, `SKEW.P`, `KURT`, `CORREL`, `PEARSON`,
    `RSQ`, `FORECAST`, `FORECAST.LINEAR`, `DEVSQ`, `GEOMEAN`, `HARMEAN`, `STANDARDIZE`,
    `FISHER`, `FISHERINV`, `PERMUT`, `F.INV`, `T.INV`, `CONFIDENCE.T` — every expected
    value checked against SciPy or NumPy, none against what this package returns.

    The argument order is what these tests are really for. Excel writes
    `FORECAST(x, known_y, known_x)` with **the y series in the middle** and BusinessMath's
    regression takes `(x, y)`; a binding that passes them straight through fits x on y and
    answers 3.05 where the answer is 6.60. In range, from the wrong line, and invisible.

  - **`MODE` and `GAMMALN` as aliases** of `MODE.SNGL` and `GAMMALN.PRECISE`, joining
    `NORMSINV` and the four beside it.

  **Measured: the coverage matrix moves 350 `have` → 379, `unreviewed` 115 → 107,
  `bindable` 41 → 20.** Of the eighteen unanswerable names, twelve were ours to answer and
  nine now do.

  **Correction.** `RANDOMNORMAL`, `MYLAMBDA` and `MAXEXP` were written up here as add-in
  functions or someone's macros. They are **`LAMBDA`s defined in the workbook**, found by
  reading the two files that actually define one:

  ```
  randomNormal = _xlfn.LAMBDA(_xlpm.x, _xlpm.y, _xlpm.x + _xlpm.y * SQRT(-2*LOG(RAND())) * COS(2*PI()*RAND()))
  ```

  So the most-called name this package cannot answer is not an add-in's — it is Excel's own
  `LAMBDA`, and the "no demand for `LAMBDA`" reading that followed from the first census was
  wrong. Two workbooks in 2,240 define one; one of them calls it 10,801 times. See
  `PROPOSAL_lambda.md`.


- **`workbook-oracle`** — the Excel oracle as a resumable executable, and `WorkbookOracle` in
  `WorkbookAudit` as the library it drives.

  It was an `XCTestCase`, and a run against 2,240 workbooks was killed at two and a half
  minutes having produced **nothing at all**. That is the third time this project has learned
  the same thing: a test over a large corpus prints only at the end, cannot resume, and gives
  no way to tell a working run from a hung one. The workbook census was abandoned twice
  before being rewritten exactly this way.

  Two files. The summary is one row per workbook and doubles as the resume state; the
  findings file names **every cell that disagreed**, with what we said, what Excel said and
  which functions the formula calls. A tally says *how many* — triage needs *which*.

  `ExcelOracleTests` now drives the same library rather than its own copy, so the measurement
  cannot drift between the two.

### Fixed

- **`0.1+0.2-0.3` is zero, as it is in Excel.** A subtraction that cancels almost everything
  now returns exactly zero rather than the residue IEEE arithmetic leaves, and a comparison
  applies the same rule wherever it sits — which is why `IF(0.1+0.2=0.3,…)` says equal while
  `(0.1+0.2-0.3)=0` says FALSE. Those two look inconsistent and are not: the first pair
  differ by 1.85e-16 *of themselves*, the second by the whole of the residue.

  **The rule was measured, not read.** Twenty formulas were put to Excel and its answers
  recorded, and the rule that accounts for all of them is about the *ratio* of a result to
  its operands, not about the result being small: `100000.1-100000-0.1` keeps its `5.8e-12`,
  a hundred thousand times larger than a residue that gets snapped away, because against
  operands of about `0.1` that is a real difference.

  It applies to **the last operation only**. `(0.1+0.2-0.3)*1` returns the residue in Excel
  and the same subtraction alone in a cell returns zero — one measured case that rules out
  correcting every addition as it happens, which is the shape anyone would write first.

  ``ExcelFinalRounding`` carries the threshold and the reasoning, and `FinalRoundingTests`
  holds Excel's twenty answers.

  **Deliberately not implemented: Excel's 15-significant-digit store**, measured in the same
  round. That one makes Excel's answers less accurate rather than differently computed, and
  this package has twice decided it does not reproduce Excel's arithmetic errors — over the
  Bessel family and over `IMSQRT`. Recorded as ADR-003 with the revisit condition stated.

- **A defined name resolves against the sheet the formula is on.** Excel scopes a name either
  to the workbook or to a single sheet, and a workbook may hold both at once — a teaching
  model in the corpus defines `MarketGrapeCost` three times, once for each of two sheets and
  once for the workbook, each pointing at a different cell.

  The evaluator resolved with no sheet at all, so it always found the workbook-scoped
  definition. **31 cells in that one workbook read another sheet's number**, answering `0.3`
  where Excel answers `0.812`. Nothing errored; the answers came from the wrong place.

  `NamedRangeCollection.resolve(_:inSheet:)` was always right — it takes a sheet and prefers
  a scoped match. It was simply never told where the question came from, while the evaluator
  held `currentSheet` in the same scope.

  **Measured on 150 workbooks none of this work had touched: 99.89% → 99.92%**, `differed`
  73 → 40.

- **A whole-row reference keeps its full width** — SwiftExcelCore moved to `0.9.0`, where
  `clipped(to:)` no longer pulls `$3:$3` back to the last populated column.

  Everything that counts *positions* depended on it. `INDEX('Raw'!$C$4:$XFD$4, 24)` answered
  `#REF!` against a fourteen-column matrix where Excel reads the blank at column Z, and
  `COLUMNS($A$1:$XFD$1)` answered `0` rather than `16384`.

  A whole column still pulls back, because there the original reasoning is right: `$B:$B`
  really does mean "whatever is in column B" rather than 1,048,576 cells. **A row is 16,384
  at most**, so the premise never applied to it, and the cost was correctness rather than
  memory. Two tests upstream asserted the old behaviour and were reversed, each recording why.

  **Measured: the corpus that drove this work reaches 100.00% — every one of 170,524
  comparable cells.** A second corpus of 150 workbooks that none of this work has seen sits
  at **99.89%**, which is the more useful number: what remains there is a long tail across
  `VLOOKUP`, `SKEW`, `GETPIVOTDATA` and a dozen others rather than the four concentrated
  causes this effort cleared.

- **A scalar function handed a range now applies to every element.** Excel does this without
  being asked — `RIGHT($BQ$1:$BW$1, 1)` is seven last-characters, not an error — and
  `SUMPRODUCT(BQ10:BW10, VALUE(RIGHT($BQ$1:$BW$1, 1)))` depends on it: the inner call has to
  produce a seven-element array for the outer one to multiply against.

  **This was 400 cells, the single largest defect the oracle found** — one formula shape
  repeated down four hundred rows, answering `#VALUE!` because `RIGHT` called `toString` on a
  range and `VALUE` did the same to what `RIGHT` returned.

  `ExcelFunction.mappedOverArrays()` is written once and applied to the scalar text
  functions. A dozen copies of the same loop is a dozen chances to broadcast differently, and
  the difference would show up as a shape rather than as an error. A single-element array
  broadcasts against a larger one; two genuinely different shapes are `#VALUE!` rather than a
  guess about which to clip. Joining functions — `CONCATENATE`, `CONCAT`, `TEXTJOIN` — are
  deliberately excluded, because handing them a range is a different request rather than the
  same one repeated.

  **Measured: agreement 99.76% → 99.99%**, with `differed` and `threw` both at zero. The only
  disagreements left in that corpus are 11 cells where a whole-row reference is clipped to the
  sheet's populated width.

- **`INDEX` accepts the `area_num` argument its reference form takes.** Seven cells in real
  workbooks write `INDEX(…, 1, 1, 1)`, and this package refused the call on its argument
  count — a harsher answer than Excel gives to a formula it accepts, and one that says
  nothing about whether the answer would have been right.

  There is only one area to choose from here, so asking for a second is `#REF!` rather than
  the first area's answer: a number of the right shape from the wrong place is the plausible
  wrong answer.

  Measured: `threw` fell from 7 to **zero**, agreement 99.75% → 99.76%.

- **`TEXT` understands date and time format codes.** `TEXT(41583, "ddd")` returned `"41583"`
  — the serial, formatted as the number it is rather than the weekday it was asked for,
  because no branch recognised the code and the numeric path took it.

  **The oracle found 127 cells doing this across 46 real workbooks**, and recorded what Excel
  had cached for every one. Those pairs are now the test, which matters because a weekday is
  exactly the sort of value that can be wrong by one and look entirely plausible: every answer
  is a real day of the week.

  Measured after the fix: **agreement 99.68% → 99.75%, and `differed` fell to zero.** Every
  remaining disagreement in that corpus is a *refusal* — a cell where this package declines
  to compute — with not one case left where it computes a different number than Excel.

  `ExcelDateFormat` carries the family: `d`/`dd`/`ddd`/`dddd`, `m` through `mmmmm`, `yy` and
  `yyyy`, `h`/`hh`, `s`/`ss`, and `AM/PM`. Two parts of it are worth knowing about.

  **`m` means minutes or months depending on what surrounds it** — minutes after an hour code
  or before a seconds code, months otherwise. `"h:mm"` and `"mm/dd"` are the same two
  characters meaning different things, and reading them alike is wrong in one case without
  ever looking wrong: both produce a small number where a small number belongs.

  **The weekday comes from the serial, not from a `Calendar`.** `WEEKDAY` already derives it
  arithmetically, which is exact across Excel's phantom 29 February 1900 — the bug lives in
  the serial numbering, so arithmetic on serials inherits it and a real calendar does not.
  There is a test asserting the two agree across a range, because two routes to one answer
  that can disagree is what `IMPOWER` and `IMPRODUCT` had just been caught doing.

- **A formula reaching into another workbook is not a disagreement.** Excel writes those as
  `[1]Sheet!A1`, and the cached value is what that other file said when the link was last
  live — a file that is not here and often no longer exists anywhere. We answered `blank`,
  which was counted as differing.

  **It put a floor under the failure rate that no amount of work could lift**, which matters
  now that the goal is to drive that rate to zero. Reclassified as not comparable, and
  measured: `differed` fell from 130 to 127 on the sample corpus while `notComparable` rose
  by the same three.

### Changed

- **`OracleFinding.children(of:)` is the only exhaustive switch over `FormulaAST` in the
  target.** Finding external references needed a second tree walk, and a second walk written
  beside the first compiles today and silently skips whatever case the language adds next —
  in exactly one of the two, with the skipping one going on returning plausible answers.
  Both now go through one switch, so a new case breaks the build once.

### Fixed

- **`IMPOWER` with an integer exponent is multiplied out, so it agrees with `IMPRODUCT`.**
  `IMPOWER("i", 2)` returned `"-1+1.22464679914735E-16i"` while `IMPRODUCT("i", "i")`
  returned `"-1"` — **two routes to one answer inside this package, disagreeing.** That is
  the failure this whole arrangement exists to prevent, and it outranks agreeing with Excel,
  which produces the same artefact for the same reason.

  The cause is swift-numerics: `pow(z, n: Int)` is `exp(log(z) · n)` despite taking an `Int`,
  so `i²` is `exp(iπ)` — and since the nearest `Double` to π is not π, `sin` of it is
  `1.2246467991473532e-16` rather than nought. That single value is the whole artefact, in
  both implementations.

  Integer exponents now go through repeated squaring: ⌈log₂ n⌉ multiplications rather than a
  logarithm and back. A fractional exponent still takes the principal branch, which is the
  logarithm however one feels about it.

  **A comment claiming the opposite has been corrected.** It said the integer overload
  "multiplies rather than taking a logarithm and back" — it does not, and nothing tested the
  claim because the assertion compared the two routes at `1e-9` where they differ at `1e-16`.

### Added

- **`conformance-workbook divergences`** — a workbook showing every point where this package
  and Excel disagree, with an independent reference beside each so the claim can be checked
  rather than believed.

  The error columns are **formulas**, so Excel computes its own distance from scipy's answer
  in front of whoever opens the file. That is a different kind of evidence from being told
  the number, and it matters here because the first conformance round got this exact question
  backwards — four differences were written up as an accuracy problem in BusinessMath on no
  evidence beyond its being the newer implementation.

  Two sheets. **Bessel** puts 45 points against scipy 1.18.1 — a grid rather than the eight
  that happened to surface, because a systematic error looks quite different from a few
  unlucky values, and the sheet totals which side is closer. **Exact values** covers answers
  that need no reference at all: J₀(0) is 1 because the series has only its first term at
  zero, and √−1 is i because that is what i means.

  The last row of that second sheet is `IMPOWER("i", 2)`, where **both** miss exactly −1 by
  1.2 × 10⁻¹⁶. It is there deliberately: a sheet about being right that only listed wins
  would be advocacy rather than evidence.

## [0.10.0] - 2026-09-14

### Fixed

**Round three: 98 questions, 87 agreed, and the loop converged.** Every remaining
disagreement is now catalogued: **ten are places where Excel is less accurate than this
package**, each attributed against a third implementation or a definition, and one was a
formatting defect fixed below.

- **The exponent marker is upper case, as Excel writes it.** `IMPOWER("i", 2)` produced the
  same fifteen digits as Excel and spelled the exponent `e-16` against Excel's `E-16`. These
  functions return text, so a letter is as much of a difference as a digit.

- **`CONVERT` refuses a prefix on `Rank` and `Reau`, which is confirmed rather than assumed.**
  The previous release deliberately left `Rank` out despite the pattern — "absolute scales
  take prefixes" — suggesting it belonged. Excel answers `CONVERT(1, "mRank", "Rank")` with
  `#N/A`. The pattern would have been wrong a **third** time on this one function; the
  prefix belongs to `K` alone.

**Round two: Excel answered 90 questions and disagreed eleven times, down from seventeen.**
The eight `#NAME?` rows are answered and agree. All five fixes below hold. Of the eleven
that remain, **eight are places where Excel is less accurate than this package** — seven
Bessel points and `IMSQRT("-1")` — and three were an over-correction fixed below.

**Round one: Excel answered 76 questions, and disagreed with this package seventeen times.** Eight of
those were the harness's fault, four are an upstream accuracy question, and five were real
defects here. All five are fixed. The workbook Excel calculated is committed beside the
coverage matrix as the evidence.

- **Complex components are written to fifteen significant digits, as Excel writes them.**
  `IMPOWER("1+1i", 3)` returned `"-1.9999999999999996+2i"` where Excel returns `"-2+2i"`, and
  `IMEXP("1+1i")` carried seventeen digits per component against Excel's fifteen. Rounding
  each component to fifteen significant figures reproduces every component of Excel's answers
  exactly — one rule, three disagreements.

  This is not cosmetic. These functions return **text**, so the digits *are* the value:
  `-1.9999999999999996+2i` and `-2+2i` are different answers to anyone comparing strings,
  which is the only comparison `IM*` output supports.

  Rounded through a decimal representation rather than by arithmetic, because scaling by a
  power of ten and rounding double-rounds — it put one component a digit out.

- **An uppercase suffix inside an `inumber` is `#NUM!`, not `#VALUE!`.** Microsoft states
  *"Using uppercase results in the #VALUE! error value"*; Excel returns `#NUM!` for
  `IMABS("3+4I")`. **The fifth documented behaviour this project has measured and found
  wrong.** `COMPLEX(3, 4, "I")` really is `#VALUE!`, so the documentation is right about half
  of it — and the distinction is coherent: unreadable *text* is `#NUM!` however it fails,
  while an argument of the wrong kind is `#VALUE!`.

- **`CONVERT` allows a prefix on `K`, and on nothing else that measures temperature.** It
  took two measurements and two wrong answers to land on that.

  This first refused prefixes everywhere, reasoning that a prefix and an offset do not
  compose — what is a milli-degree-Celsius? Excel answered `CONVERT(1, "mK", "K")` with
  `0.001`, so the refusal was wrong. The correction allowed them everywhere, and Excel
  answered `CONVERT(1, "mC", "C")` with `#N/A`.

  The original reasoning was right about `C` and `F` and wrong about `K`: a prefix scales a
  magnitude, and only an absolute scale has one. `Rank` is absolute too and is deliberately
  **not** included, because it has not been measured and the pattern has already been wrong
  twice on this exact question.

### Added

- **`conformance-workbook check` distinguishes a known divergence from a new one**, and exits
  non-zero only for the latter. Ten cases are recorded as places where the two differ and
  this package is right, each with its attribution. Without that list every run shows the
  same ten disagreements and a new one hides among them; with it, the tool is a gate that can
  be run after any change to the functions it covers rather than a report to be read once.

  A row Excel never calculated also fails, for the same reason it is reported separately: an
  unopened workbook must never look like a clean bill of health.

- **This package is sometimes more accurate than Excel, and that is now recorded as a trap
  rather than a triumph.** `IMSQRT("-1")` returns `"i"` here and
  `"6.12323399573677E-17+i"` in Excel, which computes it through polar form and keeps the
  rounding error. Being right is the correct behaviour, and it has a consequence for the
  workbook checker this project is building towards: a disagreement is **not** a workbook
  defect merely because the two sides differ. See `project/master_plan.md`.

- **`conformance-workbook` knows about `_xlfn.`** Eight of the seventeen disagreements were
  this: every function introduced after Excel 2007 must be stored in the file as
  `_xlfn.BETA.DIST`, and one written plainly is a function Excel does not have. All eight
  came back `#NAME?`, and the correlation was exact — the pre-2007 `BETADIST` answered while
  the 2010 `BETA.DIST` beside it did not. Those eight rows said nothing about this package
  and are asked again.

  The prefix is applied to the parsed tree rather than the text, because `FormulaParser`
  uppercases function names and `_XLFN.` is not what the format documents.

### Changed

- **Seven Bessel values disagree with Excel, and Excel is the one that is wrong.**

  The first round recorded this as an accuracy problem in BusinessMath. That was a guess
  dressed as a finding — two implementations disagreed and the newer one was assumed at
  fault. A third implementation settles it: **scipy agrees with BusinessMath to machine
  precision (≤ 1.0 × 10⁻¹⁵) on all seven points, while Excel is off by 2.4 × 10⁻⁹ to
  1.6 × 10⁻⁷.**

  `BESSELJ(0, 0)` makes it plain without any reference at all: J₀(0) is exactly 1 by
  definition, this package returns exactly 1, and Excel returns `1.00000000283141`.

  So Excel's Bessel functions carry roughly eight or nine correct significant digits, and
  nothing needs fixing here or upstream.

### Added

- **`CONVERT`, which closes the engineering bucket.** Excel's unit table: thirteen measures,
  roughly a hundred spellings, the decimal prefixes, the binary prefixes, and the five
  temperature scales.

  The arithmetic is one multiplication; everything that can go wrong is in the data. So the
  factors are **definitional wherever a definition exists** — a foot is exactly `0.3048` m, a
  pound exactly `453.59237` g, and every derived unit is built from those constants rather
  than from a rounded decimal, so `1 ft` is `12 in` to the last bit rather than to nine places.

  Three rules were worth writing down because each is quietly wrong by default:

  - **A name is looked up whole before any prefix is considered.** `mn` is a minute, not a
    milli-newton; `cwt` is a hundredweight, not a centi-watt; `e` is an erg *and* the deka
    prefix. Stripping prefixes first redefines all three without complaint.
  - **A prefix on an area or a volume is raised to its dimension** — a square kilometre is
    10⁶ square metres, because the prefix scales the length the unit is built from.
  - **Temperature is affine.** Every other conversion is a ratio; these carry an offset, and
    a scale factor alone is correct only at zero.

  Two choices are inferred rather than documented, and noted where they are made: prefixes
  are refused on temperature, and an unknown unit gives `#N/A`.

- **The complex family — `COMPLEX` and the twenty-five `IM*` functions.** swift-numerics has
  every operation they need and BusinessMath supplies the `a+bi` codec, so each binding is
  parse → call → format. None of the arithmetic is written here.

  **The work is the text**, because Excel's complex numbers are strings and the rules about
  those strings are entirely Excel's. The suffix is `i` or `j` and never `I` or `J` — and the
  BusinessMath parser accepts all four, so that strictness had to live in the binding. A
  result carries the suffix its arguments used. A number with no imaginary part is written as
  a bare real: `COMPLEX(7, 0)` is `"7"`, not `"7+0i"` — which settles an open question the
  plan had recorded as *"do not assume it"*, and the codec already agreed. Text that is not a
  complex number is `#NUM!` rather than `#VALUE!`, and `"3+4"` is not one, because a missing
  suffix is not an implied suffix.

  The tests assert identities rather than values — `IMTAN("1+1i")` is a number nobody can
  check by eye, so a table of them would test the transcription. `IMEXP` undoes `IMLN`,
  `IMSQRT` squares back, sin² + cos² is 1, cosh² − sinh² is 1, and each of the five
  reciprocal spellings is asserted against a division rather than trusted.

  `IMSEC` and its four relatives stay here rather than going upstream as the Bessel functions
  did, on the test the plan states: *could a second implementation disagree with the first?*
  For `1/cos(z)` there is no second algorithm to disagree — no series, no convergence
  criterion, nothing to get wrong but the division. For a Bessel function there was.

- **`BESSELI`, `BESSELJ`, `BESSELK` and `BESSELY`**, bound to BusinessMath's `besselI`,
  `besselJ`, `besselK` and `besselY`. The mathematics is emphatically not here: a Bessel
  function is a real algorithm — series near the origin, asymptotics far from it — and a
  second implementation could disagree with the first, which is the boundary this package
  draws. What lives here is Excel's argument handling: a fractional order is **truncated
  rather than rounded**, a negative one is `#NUM!`, and `K` and `Y` are refused at and below
  zero where they are singular while `I` and `J` are perfectly ordinary there.

  The tests assert **relationships, not remembered constants** — three tests in this project
  have failed correct code because an expected value was recalled rather than read, and a
  Bessel value is exactly the kind of number nobody can check by eye. So they check the
  recurrences that define the functions, the values at zero, and the Wronskian
  `Jₙ₊₁(x)·Yₙ(x) − Jₙ(x)·Yₙ₊₁(x) = 2/(πx)`. The Wronskian is the one that earns its place: it
  fails if `J` and `Y` are individually right but mismatched, which no per-function test can
  catch. The modified recurrences carry a sign difference from the ordinary ones, so writing
  either with the wrong operator gives a plausible number and fails here.

### Changed

- **BusinessMath moved from `3.0.0-alpha.3` to `3.0.0-alpha.4`**, which carries `besselI`,
  `besselJ`, `besselK` and `besselY` in `Statistics/SpecialFunctions/`. All four take an
  integer order, matching Excel's `BESSELI(x, n)` signature exactly, so the four engineering
  rows they answer are binding work rather than mathematics to be written.

  Only `Package.resolved` changed: the declared range was already
  `.upToNextMinor(from: "3.0.0-alpha.3")`, and its comment had anticipated this — *"The range
  admits 3.0.0-alpha.4 and 3.0.0 final without a Package.swift edit."* 1,263 tests in the main
  suite and 1,320 across all four, zero failures; gate 45/45 at zero warnings.

- **Coverage: 467 functions registered, up from 436.** EXCEL `unreviewed` falls from 146 to
  **115**, and **the engineering bucket is closed** — all 48 rows answer. `compatibility` was
  closed earlier in the same release, so two of the ten categories are now done.

  What remains unreviewed: lookup 24, financial 21, math 20, information 13, database 12,
  logical 11, text 7, datetime 7.

- **swift-numerics is now a declared dependency** rather than one reached through
  BusinessMath. The `IM*` family binds `Complex` directly, and depending on a transitive
  package without declaring it breaks the day the intermediate stops needing it.

### Added

- **Excel's twenty-six pre-2010 statistical spellings.** `CHIDIST`, `TINV`, `CRITBINOM` and
  the rest. Excel renamed the statistical library in 2010 and then kept every old name
  working for ever, because twenty years of workbooks call them; a reader that answers only
  the modern spellings cannot open a file written before 2010, which is most of the files
  there are.

  **Every one delegates.** `CHIDIST` calls `CHISQ.DIST.RT` and returns what it returns. A
  second implementation that could disagree with the first is the failure this package exists
  to prevent, and delegation makes drift impossible rather than merely unlikely.

  Twenty-one are plain aliases. Five are not, and each returns a plausible number rather than
  an error when read wrongly:

  | Legacy | Modern | Why it is not an alias |
  |---|---|---|
  | `BETADIST` | `BETA.DIST(…, TRUE, [A], [B])` | cumulative only, and the flag sits **before** the bounds — appending it would pass `TRUE` as `A` |
  | `HYPGEOMDIST` | `HYPGEOM.DIST(…, FALSE)` | the mass function, not the cumulative |
  | `LOGNORMDIST` | `LOGNORM.DIST(…, TRUE)` | cumulative only |
  | `NEGBINOMDIST` | `NEGBINOM.DIST(…, FALSE)` | the mass function |
  | `TDIST` | `T.DIST.RT` **or** `T.DIST.2T` | dispatches on a tails argument, and refuses negative `x` |

  `TDIST` is the sharpest: it is **not** `T.DIST.2T` under an old name, and reading it as one
  hands every single-tailed caller exactly twice the probability they asked for.

- **`BETA.DIST`**, which had to be written rather than delegated to — it was the one modern
  statistical function still missing, and surfaced from the other end because `BETADIST` had
  nothing to stand on. Its bounds rescale the distribution, so the **density is divided by the
  width** while the cumulative form is left alone: a density carries a Jacobian through the
  change of variable and a probability does not.

  The tests hold it against `BETA.INV` rather than against a literal, because agreeing with an
  existing inverse checks the parameterisation, which is where a beta implementation goes wrong.

### Changed

- **Coverage: 436 functions registered, up from 409.** The `unreviewed` bucket falls from 172
  to 146 EXCEL rows, and the whole `compatibility` category is now resolved.

  **Provenance, stated because it matters:** these pairings come from Microsoft's
  documentation rather than from Excel. Documentation has been wrong four times in this
  project's life. No workbook in the 2,240-file corpus calls any of these, so there was
  nothing to check them against; the five non-aliases are the ones worth a hand-built
  workbook, in the way the Solver encodings were.

## [0.9.3] - 2026-09-12

### Changed

- **SwiftXLSX pin moved to 0.25.0.** No source change; this release exists so the
  package can resolve at all.

  SwiftXLSX's repository was deleted and recreated on 2026-09-12 to remove material
  belonging to an unrelated project from its published history. That took tags
  v0.6.0 through v0.24.1 with it, including the revision this package pinned — so
  **v0.9.2 and every earlier tag can no longer resolve.**

  0.25.0 is deliberately above every previously published SwiftXLSX version, so no
  version number points at two different commits. SwiftPM records a
  trust-on-first-use fingerprint per version, and re-pointing an existing number
  makes every later resolve fail with *"does not match previously recorded value"*
  on every machine that had seen it — including CI runners nobody can reach.
  Reusing 0.24.1 would have been the quiet way to break this for everyone.

  If a resolve fails with that message, delete
  `~/.swiftpm/security/fingerprints/swiftxlsx-*.json` and try again; the old
  records name revisions that are gone.

1,251 tests pass against the rebuilt SwiftXLSX.

## [0.9.2] - 2026-09-12

### Added

- **`WorkbookContainer`**, a target that says what a file *is* before anything parses it as a
  workbook. `ContainerKind(of:)` reads the leading signature: a ZIP, an OLE2 compound file
  (which for an `.xlsx` means ECMA-376 encryption), or neither.

  It exists because a census of 2,240 workbooks found four a ZIP reader refused and reported
  all four as damaged. They were three different things. Two were **password-protected and
  completely intact** — the package a ZIP reader wants is a stream *inside* the compound
  container, so it sees a broken archive. One was a **plain-text memo saved with an `.xlsx`
  extension**. Exactly one was genuinely corrupt. The real corruption rate in that corpus is
  1 in 2,240, not 4.

  It sits outside `SwiftExcelFunctions` on purpose: that library promises no dependency on a
  file format, and this is entirely about file formats.

- **`WorkbookDecryptor` opens password-protected workbooks.** ECMA-376 agile encryption —
  AES-CBC with an iterated-hash key derivation, the scheme Excel has written since 2010.
  `CompoundFile` reads the OLE2 container the package is hidden inside, walking both the FAT
  and the mini-FAT, with sector chains guarded against loops so a malformed file cannot hang
  a scan. Nothing about the scheme is assumed: salt, spin count, key length, cipher and hash
  are all read from the file.

  The password is verified *before* the package is touched, using the verifier the format
  carries for that purpose. A wrong password is reported as one rather than yielding rubbish
  that fails later as a corrupt archive — which would send someone hunting for a damaged file
  instead of a better password.

  `workbook-census` gains `--password P`, which turns an encrypted workbook into an ordinary
  one for a directory whose files share a known password.

### Fixed

- **SHA-1 was dropped from the decryptor and it broke the only files the feature existed
  for.** The reasoning was that agile encryption implies Excel 2010 or later, which writes
  SHA-512, so carrying a broken hash was unnecessary. That reasoning was checked against the
  project's own generated fixture, which used SHA-512 — and the two real 2012 workbooks that
  prompted the whole feature declare **SHA-1 with 128-bit AES**. Every test stayed green while
  the feature stopped working on its motivating case.

  This is the same failure recorded three times already this cycle: a hand-built fixture
  agreeing with the code about something neither had checked. The fixture set now carries a
  SHA-1/AES-128 workbook, generated by an independent encryptor and verified against a third
  implementation, plus a test asserting the fixture really does declare SHA-1 — a fixture
  quietly regenerated with different parameters would otherwise leave the suite green while
  testing the same path twice.

  Reading SHA-1 here is not a security choice; the file names the algorithm and the
  alternative is refusing to open the document. It is held at `weakCryptoPolicy: justified`,
  which still reports any weak hash that does not carry a written reason on the line above
  it — see the note in `.quality-gate.yml`.

### Changed

- **The census distinguishes those cases** rather than calling them all `unreadableWorkbook`.
  New outcomes `encryptedWorkbook` and `notAWorkbook`, both of which count as answers — a
  password-protected workbook gives the same answer every pass, so re-examining it for ever
  would be its own bug. "This needs a password", "this is not a spreadsheet" and "this file
  is damaged" ask three different things of whoever reads the report.

## [0.9.1] - 2026-09-11

### Fixed

- **Every numeric Solver setting was read as text and discarded.** A defined name whose
  value is a bare number — `solver_eng = 2`, `solver_num = 6` — is not a cell reference, so
  `DefinedNameResolver` cannot resolve it and hands back `.formula(.text("2"))` rather than
  `.formula(.number(2))`. The reader matched only `.number`. In every real workbook that
  meant **every model reported `grgNonlinear` whatever engine it named, and every model
  reported no constraints at all**, because `solver_num` failed the same way. The runner
  would have solved unconstrained versions of real problems and reported success.

  The census found it within minutes of first working, which is the whole argument for
  having built it. The corpus shows the before and after directly: the pre-fix rows read
  100% `grgNonlinear` with an empty relations column in **every** row, and the same files
  re-read now resolve `simplexLP` where the workbook asks for it and decode relation codes
  1 through 6 — every code Excel defines. `Graded Assignment 1.xlsx` is the cleanest single
  case: four models, read as four GRG models before and four Simplex LP models after.

  The completed scan puts numbers on it. Across **2,240 workbooks**, 339 carry `solver_`
  names and they hold **1,481 models** — 1,264 `grgNonlinear`, 201 `simplexLP`, 16
  `evolutionary`. Before the fix every one of those would have read as GRG with no
  constraints. **No workbook produced names without a model**, so the reader assembled
  something from all 2,236 it could open.

  The existing tests could not have caught it. They build `NamedRangeTarget` values by
  hand, which encodes an assumption about the parse rather than exercising it — the third
  time this week a hand-built fixture agreed with the code about something neither had
  checked, after the corpus provenance and the furigana corruption.
  `ExcelSolverReaderParseTests` goes through the textual form throughout, deliberately.

- **A label no longer swallows a number.** Now that numbers arrive as text, `"10"` is a
  bound and `"integer"` is a declaration, and they are the same case of the same enum.
  `label(_:)` refuses anything that parses as a `Double`, which makes the order callers try
  them in unnecessary to know.

- **A read that failed was recorded as a workbook that cannot be read**, and the census file
  is its own resume state, so that verdict was permanent. A run recorded 42 workbooks as
  `unreadableFile`, every one of them `POSIX 60 "Operation timed out"` — a file provider that
  had not materialised the file yet — and every one of them read correctly minutes later.
  Three had read correctly in the run *before*. Nothing in the output said they were
  different from genuine failures, and no later pass would ever have retried them.

  A 43rd was `POSIX 4 "Interrupted system call"`: the operator stopping the run. Stopping a
  census was supposed to be free, and instead it wrote off whichever file was in flight.

  Transient failures are now retried, and recorded as `transientFailure` if they still fail.
  The row is written — leaving it out would make "tried and deferred" identical to "never
  reached" — but `CensusRow.completedPath(ofLine:)` excludes it, so a resumed run examines
  the workbook again. `TransientRead` decides what qualifies, and the list is deliberately
  short: `ETIMEDOUT`, `EAGAIN`, `EINTR`. A code that does not belong there would turn a
  permanent failure into an unbounded one.

- **A DocC comment named a test that does not exist** — `ExcelSolverReaderRealFileTests`,
  for what shipped as `ExcelSolverReaderParseTests`. The comment's claim is the load-bearing
  part: it says which test exercises the parse rather than assuming it, and a reader who
  goes looking must find it.

### Added

- **`SolverRun.solve(cells:names:inSheet:)`** — the one-call entry point that joins reading
  and solving. It takes a `CellValueProvider` and a name collection rather than a
  `Workbook`, because this package promises no dependency on a file format: `Workbook`
  belongs to SwiftXLSX, and the file-reading half belongs in `WorkbookAudit`.

- **`workbook-census`**, an executable that scans a directory for classic Solver models and
  writes one TSV row per workbook. Two earlier attempts at this census were `XCTestCase`s
  and both were abandoned mid-run having produced nothing: a test prints only at the end,
  cannot resume, and gives no way to tell a working run from a hung one. This one writes and
  flushes per workbook and uses the output file as its own resume state, so it is worth
  stopping.

  ```
  swift run workbook-census ~/Documents --out census.tsv [--limit N]
  ```

- **`--limit N`**, to take the corpus a batch at a time. Batching needed no new state —
  stopping the run has always been safe, because every row is flushed as it is written — but
  a chosen batch beats a stopwatch. What it left behind is always reported, so a partial
  census cannot be mistaken for a complete one.

  Worth knowing before picking a batch size: **each run re-walks the directory tree, and on
  this corpus that costs about 24 seconds** against roughly 22 workbooks a minute of actual
  work. Batches of several dozen spend more time finding the files than reading them; a few
  hundred at a time amortises it.

### Changed

- **Licensed AGPLv3, with a commercial licence available** — see `LICENSE` and
  `LICENSING.md`. The network clause (§13) is deliberate: running this as a hosted service
  is a form of use the copyleft is meant to reach. The permissive layers of the family —
  SwiftExcelCore, SwiftXLSX, SwiftZIP — stay Apache 2.0, because copyleft may depend on
  permissive but never the reverse.

## [0.9.0] - 2026-09-11

### Changed

- **The Solver encodings are measured rather than documented.** Three workbooks built in
  Excel for Mac, saved without solving, and read directly: all six relation codes, all
  three engines, both `solver_neg` settings, and `solver_typ` for Max and Value Of matched
  Frontline's published layout. Only `solver_typ = 2` for Min stays inferred.

  It mattered that this was checked. Documentation had been wrong four times this cycle —
  `FORECAST.ETS`'s aggregation codes were a different base *and* a different order than
  published, and duplicate timestamps aggregate where the docs say `#VALUE!`. Here it was
  right, which is only knowable by looking.

### Added

- **A model with no objective is a feasibility search**, which Excel allows and this
  refused. The file settles it unambiguously: `solver_opt` is omitted entirely rather than
  written empty. `Solution.objective` is now optional, because reporting zero or NaN for a
  model that has no objective would be inventing one.

- **`SolverModel.formatVersion`**, recording `solver_ver` — measured as 2. It is the one
  value that could renumber every other encoding with nothing else in the file to say so.

- **`SolverModel.Bound.label(_:)`**, for the integrality declarations. Excel writes the
  *word* `"integer"`, `"binary"` or `"alldifferent"` where a bound would go.

### Fixed

- **Solver models are sheet-scoped and were read as though they were not.** Excel writes
  every `solver_` name with a `localSheetId`, so a workbook may hold several; reading them
  into one namespace merged two models into one made of neither's parts. `models(from:)`
  returns one per sheet.

- **`solver_lin` was written and ignored.** It is the pre-2010 "Assume Linear Model"
  checkbox, and a workbook old enough to carry it without `solver_eng` declares a linear
  model — read as GRG, that solves a linear program with a nonlinear method.

- **`solver_adj` may name several non-contiguous areas** — measured as
  `Sheet1!$A$1:$A$3,Sheet1!$C$3`. It resolves to neither a cell nor a range, so it arrived
  as text and yielded no variables at all, which reads as a model with nothing to adjust
  rather than one that could not be parsed.

- **`solver_typ` is written even when there is no objective**, so `sense` is meaningless
  on its own. Recorded on the property rather than left as a trap.

## [0.8.1] - 2026-09-11

### Added

- **All-different and "Make Unconstrained Variables Non-Negative" are implemented**, where
  0.8.0 refused them. Both are in the free Excel Solver, so refusing them was not an answer.

  All-different is Excel's `dif`: the group takes the integers `1…N`, each exactly once.
  It is satisfied by *decoding* rather than constraining — the optimizer's values are read
  as sort keys and the permutation is their rank order, so every point in the search space
  maps to a valid permutation and no infeasible point exists to be found.

  `solver_neg` is a constraint generator rather than a flag: it adds `x >= 0` to every
  variable, which is why turning it off changes the answer rather than merely permitting a
  different one. Simplex splits free variables into `x⁺ - x⁻` rather than refusing them.

- **`Solution.worstViolation` and `isFeasible(within:)`**, reporting what Excel reports as
  "Solver could not find a feasible solution", measured at the point the caller is given.

### Fixed

- **Constraints were enforced by penalty, which makes a hard constraint soft.**

  NelderMead penalises every constraint it is given, `.linearInequality` included — only
  branch-and-bound's relaxation and simplex enforce those exactly. So a bound on the general
  path was a *preference*, traded against the objective: non-negativity settled at `-0.005`,
  and an all-different group starting at `(0, 0, 0)` stayed there.

  Projecting the answer afterwards is worse than the symptom. It does not fix infeasibility,
  it moves it — clamping a variable that an equality ties to another breaks the equality
  instead — and it leaves the reported point inconsistent with the objective the optimizer
  saw. Bounds are now clamped *inside* the objective, so every evaluation happens at a
  feasible point and the function being minimised is the bounded one. Not on the simplex
  path, where bounds are real constraints and clamping would make the objective nonlinear:
  `max(x, 0)` is not linear, and the linearity probe would reject a perfectly linear model.

## [0.8.0] - 2026-09-11

### Added

- **An Excel Solver model now reads and solves.**

  Solver stores its model in *defined names* — `solver_opt`, `solver_adj`,
  `solver_lhs1`/`rel1`/`rhs1` — not in cells or functions, which is why no amount of
  function coverage ever revealed whether a workbook carried one, and why a function-level
  coverage matrix is structurally blind to it.

  Three pieces: `SpreadsheetFunction` reads a sheet as `([Double]) -> [Double]` by setting
  cells, recalculating in dependency order and reading others; `ExcelSolverReader` reads the
  model; `SolverRun` joins them to BusinessMath's optimizers.

  **The engine is dispatched, not obeyed.** `SolverModel.engine` records what the workbook
  asked for; `Solution.engineUsed` reports what ran. So a model declared for Excel's plain
  Simplex can be solved by branch-and-cut or a robust optimizer — the model and the method
  never get entangled.

  Integrality goes to branch-and-bound and outranks the nominated engine, as it does in
  Excel. Simplex probes the sheet for linear coefficients and **refuses a nonlinear model**,
  which is Excel's own answer rather than a silent change of engine. Evolutionary dispatches
  to differential evolution and refuses an unbounded variable, as Excel does.

- **`FORECAST.ETS`, `.CONFINT`, `.STAT` and `.SEASONALITY`**, with the argument layer
  beneath them: timeline step detection, `data_completion`, and `aggregation`.

  Three of those behaviours are measured against Excel rather than taken from the
  documentation, which is wrong about all three: duplicate timestamps are *aggregated*, not
  `#VALUE!`; the aggregation codes are 1-based and alphabetical, not 0-based in the
  published order; and SMAPE uses the halved denominator. `SEASONALITY` answers `0` when no
  cycle is detected, also measured.

- **`PHONETIC`, `ASC`, `DBCS`, `JIS` and `BAHTTEXT`.** `DBCS` and `JIS` are one function
  under two names, on Microsoft's own account. `BAHTTEXT` was written from the documented
  Thai grammar and then verified against Excel, seven values for seven.

### Fixed

- **`allDifferent` was silently treated as integrality.** It requires the variables to be
  pairwise distinct, which is strictly stronger than requiring them to be whole. It is now
  refused, because `IntegerProgramSpecification` cannot express it.

- **`solver_neg` was ignored.** Excel's "Make Unconstrained Variables Non-Negative" controls
  whether a simplex solver can answer at all, since simplex assumes `x >= 0` structurally.

### Requires

- SwiftExcelCore 0.8.0 and SwiftXLSX 0.24.1. The latter fixes two defects found while
  scoping this work rather than by testing it: furigana was being concatenated into cell
  values, and a long identifier overflowed the formula lexer and **killed the process**.

## [0.7.1] - 2026-09-08

### Changed

- **Dependency pins loosened: `SwiftExcelCore` to `from:`, `SwiftXLSX` to
  `upToNextMinor`.**

  Every recorded justification for the `exact:` pins was a *lower* bound — "0.13.0
  is the release that removed these functions; anything **earlier** would import a
  second `FormulaEvaluator`" — and none required exactness.

  The strict form had a cost. When `DependencyGraph` moved to SwiftExcelCore,
  BusinessMathExcel could not resolve at all: this package wanted Core `exact 0.5.0`
  and SwiftXLSX 0.23.0 wanted `exact 0.6.0`. Two `exact:` pins on the same shared
  package deadlock the moment they differ, and the only exit was a coordinated
  release of everything downstream.

  The constraint they existed to enforce is unchanged: the family must unify on one
  SwiftExcelCore, because two versions would mean two `CellValue` types and nothing
  would typecheck. `from:` enforces that *better* — it resolves to the highest
  version satisfying every consumer, where `exact:` simply fails.

  SwiftXLSX is `upToNextMinor` rather than `from:` because this family ships
  breaking changes in minor versions while it is pre-1.0 — two `refactor!` commits
  in one day. A patch should flow freely; a minor should be a deliberate bump.


## [0.7.0] - 2026-09-08

### Removed

- **`enum SwiftExcelFunctions` and its `version` constant.** The same scaffold
  residue removed from SwiftExcelCore in its 0.7.0, and removed here for the same
  three reasons.

  It shadowed the module name, so a qualified `SwiftExcelFunctions.SomeType` did not
  resolve. It was **wrong** — `version` read `"0.1.0-dev"` while the package was at
  0.6.0, because a hardcoded string has nothing keeping it in sync with the tag.
  And its only test asserted that a literal was non-empty, which cannot fail.

  That both packages carried the identical constant with the identical stale value
  is the evidence: this is what the pattern does, not an oversight in one place.
  Neither SwiftXLSX nor BusinessMathExcel has one.

  Module documentation already lives in the DocC catalogue, more fully than the
  enum's doc comment carried it.

  **Migration:** none expected. Take a version from your dependency graph, where it
  is true.


### Added

- **The simulation stack.** A Risk Solver workbook can be read, recognised, run and read
  back. Seven sheets across six real models run end to end, 36 outputs, reproducing
  exactly under seed.
  - `PsiRecognizer` — what a formula declares about its role: distribution calls, output
    markers, and property functions it cannot model, named rather than absorbed.
  - `ModelSurveyor` / `ModelSurvey` / `UncertainCell` — the same across a sheet, assigning
    the input indices a sampler fills. Indices are per *call site*, so two draws in one
    cell stay independent.
  - `PopulatedCellProvider` — optional enumeration for a provider that knows its own keys.
    Without it a survey scans the bounding rectangle: measured 34.8s against 1.08s on six
    real workbooks.
  - `SimulationResultProvider` and `EvaluationContext.simulation` — the seam that lets
    `PsiMean(B4)` read a completed run. Without one every statistic answers `#N/A`, which
    is what Risk Solver shows before a simulation.
  - `BuiltinRiskSolverStatistics` — `PsiMean`, `PsiStdDev`, `PsiPercentile`, `PsiTarget`,
    `PsiXtoP`, `PsiBVaR`, `PsiCVaR`. Measured at 70 of 314 Psi calls in real workbooks.
  - `InterpretedRun` / `SimulationRun` / `TrialRunError` — the trial loop, with the
    evaluation order validated rather than trusted.
  - `Lowerer` / `LoweredModel` / `LoweringFailure` — `FormulaAST` compiled to BusinessMath
    bytecode. 83% of real outputs lower; the rest are cross-sheet.

- **`WorkbookAudit`** — a new library product: a validator that audits a spreadsheet the
  way the quality gate audits code. Its own target because it reads files, which
  `SwiftExcelFunctions` promises not to.
  - `Finding` / `Severity` / `WorkbookChecker` / `Requirement` / `AuditModel` /
    `WorkbookAuditor`. A checker declares what it needs — structure, recomputation, or a
    simulation — before any work happens, so a run that wants a structural check never
    pays for a Monte Carlo. Findings sort worst-first then in reading order, totally and
    deterministically, because a validator whose output moves between runs cannot be
    diffed in CI.
  - **`circular-reference`** (enabled). Cells that depend on themselves, directly or
    through a chain. The graph is built over the whole workbook rather than a sheet at a
    time, so a cycle closing across two sheets is still found — measured on real models,
    2 of 6 are cross-sheet and the largest has 69% of its formulas referencing another
    sheet. Census: **0 findings across 6 real workbooks**.
  - **`consistency`** (opt-in, `WorkbookAuditor.experimental`). One cell in a run
    differing from its neighbours, compared modulo relative offset so a copied formula
    counts as the same shape. It finds real defects — in one real model,
    `E19 = E17*E18*D13` where every neighbour reads `E13`. It also produced **249 findings
    across 33% of six real workbooks**, and a checker firing that broadly gets a validator
    switched off wholesale, taking the checker that *was* right with it. Opt-in until the
    rate comes down.

### Changed

- **Depends on SwiftExcelCore 0.6.0 and SwiftXLSX 0.23.0, and the dependency graph
  is now reachable from the library.**

  `DependencyGraph` moved to SwiftExcelCore, so this package can build one from a
  `CellValueProvider` without a file-format dependency. Verified rather than
  assumed: a probe in the **library** target — not the test target, which could
  always reach SwiftXLSX — compiles `DependencyGraph(cells:provider:)` against
  SwiftExcelCore alone, and the library target imports SwiftXLSX in no file.

  That closes the case the move was argued on. A trial loop needs a topological
  order with cycle detection, and the alternative to reaching this one was a second
  Kahn's implementation — two orders that could disagree, in a package whose
  evaluator relies on the first.

  The type's designated initialiser there is `init(cells:provider:)`. The cell set
  is supplied rather than discovered because `CellValueProvider` answers "what is at
  this address?" and cannot be asked "which addresses do you have?" — the same gap
  `PopulatedCellProvider` names on this side.


- `FunctionRegistry.canonical(_:)` is now public. `WorkbookAudit` needs the same `_xll.` /
  `_xlfn.` normalisation the recognizer does, and the alternative to exposing it was a
  second copy that could drift.
- **The formula tree is described once.** `FormulaAST.children`, `.binary` and
  `.walk(maxDepth:_:)` replace four separate walkers that each enumerated the AST's cases
  — the recognizer's function visitor, the trial loop's precedent extractor, and the
  lowering pass's audit and builder. The cost was never the lines; it was that adding a
  node kind meant finding all four, and the compiler only helps where a switch is
  exhaustive.

### Fixed

- **An absolute reference is the same cell.** `CellRef` hashes its `$` markers, so a trial
  computing `B8` stored it where a formula reading `$B$8` could not find it — falling
  through to the value Excel cached before the simulation began, and reporting statistics
  about a model that never propagated.
- **`PsiTarget` is cumulative and inclusive.** The coverage matrix recorded
  `probabilityAbove`, the complement; `probabilityBelow` then proved to count strictly
  `<` where Frontline documents "less than or equal to". On a Bernoulli output that is
  0.30 against 0.00 — the entire probability mass at the boundary.
- **`PsiOutput()` is not required.** A cell another formula asks a statistic about is an
  output by virtue of being asked about. Requiring the marker rejected a real 126-call
  model outright and cost another eight of its fourteen outputs.

## [0.6.0] - 2026-09-08

### Added

- **A structural recognizer for simulation models** — `PsiRecognizer`,
  `RecognizedFormula`, `DistributionCall`, `ModelSurvey`, `UncertainCell`.

  Reads what a formula *declares* rather than what it computes: which cells draw
  from a `Psi*` distribution, which carry `PsiOutput()` and are collected, and
  which do both. It evaluates nothing, so it works on a workbook with no add-in
  present, no seed and no engine attached — which is the state every archived
  Risk Solver model is in.

  `ModelSurvey` lifts that to a sheet, assigning each uncertain cell an input
  index. `unhandledProperties` reports property functions it does not model rather
  than dropping them: leaving one among the parameters would shift every parameter
  after it and still compute, which is the failure mode hardest to see.

### Added

- **`PsiMetalogFit` and `PsiMetalog2Fit`**, which needed no answer after all.

  Frontline does not say which of `x_values`/`y_values` carries the probability, and
  backwards the fit is to transposed data — an answer, and the wrong one. But a
  fitting probability is *defined* as strictly inside `(0, 1)` and distinct, and
  `DistributionMetalog` enforces exactly that, so the vector is identified rather
  than assumed: whichever satisfies the definition, is it, in either position.

  Where both vectors could be probabilities — a market-share or utilisation model
  does this — the call is refused rather than guessed.

  The two share a signature in Frontline's own reference and nothing distinguishes
  them, so they are bound alike: two names behaving the same is a smaller error than
  one of them quietly fitting a different distribution.

- **`PsiMVShuffle` is bound to `MultivariateResample`, and says so.**

  Frontline shuffles without replacement. That is a property of a *sequence* —
  `MultivariateShuffle.next(using:)` is `mutating` and removes each row as it draws —
  and a cell evaluation has no memory of the previous one. Taking row 0 of a fresh
  permutation would *look* like a shuffle and would in fact be resampling, so this
  calls the resampler under its own name instead of dressing one up as the other.
  What it costs is stated: a full pass reproduces the empirical joint distribution
  with no sampling error, and independent draws do not.

- **Fifty more Risk Solver distributions**, on BusinessMath 2.15.0 — which
  implemented the whole 52-row completeness delta and adopted the proposal's shape.
  **104 of 113 Psi distribution rows are now bound.**

  **The 28 `*Alt` rows are one binding, not 28.** They are the same distributions
  parameterised by what the modeller knows — `PsiNormalAlt(0.05, 1.5, 0.95, 4.5)`
  says "the 5th percentile is 1.5 and the 95th is 4.5". One generic function reads
  Frontline's pairs into `ParameterConstraint`s and hands them to
  `PercentileParameterisable.fitting(_:)`.

  Arguments come in **(name, value) pairs**, and a *numeric* name is a probability
  while a *textual* one names a moment or native parameter. That split is what
  removes the ambiguity a purely numeric convention would have: a bare `(0.05, x)`
  cannot say whether it means "the 5th percentile is x" or "the scale is 0.05", and
  Excel's `5%` formatting is display rather than value, so it does not reach the AST.

  Tested by **round trip** rather than against a table: state a distribution's own
  quantiles back to it and the fit must recover it. That works for every conformer
  without a fixture apiece, and it fails loudly if a solve is wrong.

  Also bound: `PsiPert`, `PsiErf`, `PsiPareto2`, `PsiBetaGen`, `PsiBetaSubj`,
  `PsiHistogram`, `PsiCumulD`, `PsiNormalSkew`, `PsiTriangGen`, `PsiMetalog2`,
  `PsiMetalogSPT`, `PsiFit`; the ARMA family (`PsiAR2`, `PsiMA1`, `PsiMA2`,
  `PsiARMA11`), `PsiARCH1` and `PsiEGARCH11`; and the multivariate rows
  (`PsiMVNormal`, `PsiMVLogNormal`, `PsiMVResample`, `PsiMVShuffle`), which answer a
  **vector** that the existing spill machinery distributes — exactly as Frontline
  documents them ("you must array-enter a formula").

- **`RandomSourceGenerator`** — a `RandomNumberGenerator` view of a `RandomSource`.
  The multivariate distributions have no scalar inverse to drive from a uniform, so
  they ask for a generator; sampling the marginals independently instead would
  type-check and discard the correlation, which is the whole point of them. The
  bridge packs two uniform draws into each 64-bit value, is deterministic, and still
  takes every bit from the caller.

- **Forty-five more Risk Solver distributions**, taking the Psi distribution
  surface to 54 of 113 — everything BusinessMath 2.14.0 can back except two.

  Same machinery as the nine: inverse transform through the distribution's own
  `quantile`, property functions read from the unevaluated AST. What is different
  is that most of the work is *parameterisation*, because Frontline and
  BusinessMath often name the same distribution with different parameters. Each
  conversion is asserted exactly rather than by a range check, since a range check
  passes with the conversion removed:

  - **`PsiExponential(beta)` states the mean; `DistributionExponential` takes the
    rate.** Un-inverted, β = 100 gives a mean of 0.01 — right sign, right shape,
    wrong by four orders of magnitude.
  - **`PsiLogistic(mu, s)` states the scale; the type takes the deviation**, which
    is `s·π/√3`. Passed through, the distribution is narrowed by 1.814 at every
    percentile except the median.
  - **`PsiGamma` has a real shape, so it cannot use `DistributionGamma`**, which
    takes `r: Int` and builds the draw as a sum of `r` exponentials. Rounding 2.5
    to 2 answers a different distribution; the free `gammaQuantile` takes reals.
  - **`PsiLogNorm2` takes log-scale parameters unconverted**, the counterpart to
    `PsiLogNormal`, which takes arithmetic ones. Binding both alike makes one wrong.

  Two suite-wide assertions cover all forty-two: every one draws a finite number at
  three probabilities, and **every quantile is monotone** — which a binding that
  scrambled a parameter into a shape slot would break while still returning finite
  numbers.

  `PsiShuffle` is bound and documented as approximate: sampling without replacement
  is a property of a *sequence*, and a cell evaluation has no memory of the last
  draw. `#NAME?` on an otherwise-readable workbook was the worse option.

  **`PsiAR1`, `PsiGARCH11` and `PsiMetalog` are bound**, which they nearly were not:
  the first two looked like they needed simulation state a cell cannot carry, until
  Frontline's signatures showed the previous state is passed *in* — `val0`, `err0`,
  `stdev0` are arguments, supplied by the cell above, because a spreadsheet cell has
  no memory. `PsiMetalog`'s trailing `prop_fcns` is not a parameter either; it is
  Frontline's general property-function slot, already stripped before a distribution
  sees its arguments.

  Two remain: `PsiMVLogNormal`, which is documented and unambiguous but needs an RNG
  bridge and an array-returning sampler because it spills a correlated vector across
  cells; and `PsiMetalogFit`, whose signature does not say which of `x_values` and
  `y_values` carries the probability. Recorded in
  `project/plans/psi_upstream_gaps.md`.

- **The nine Risk Solver distributions the corpus calls.** `PsiBernoulli`,
  `PsiNormal`, `PsiLogNormal`, `PsiTriangular`, `PsiDiscrete`, `PsiUniform`,
  `PsiBinomial`, `PsiIntUniform`, `PsiPoisson` — 1,166 of the Psi family's 1,950
  corpus calls, and the point at which a workbook that used Risk Solver can be
  read without it.

  The mathematics is BusinessMath's. Sampling is by inverse transform: one
  uniform from the caller's `RandomSource` through the distribution's own
  `quantile`, so the randomness stays where this package has always kept it and
  nothing reaches for system entropy.

  **Every one is a context function**, because a property function cannot be
  recognised by its value — `PsiBaseCase(99)` and a literal `99` both arrive as
  `.number(99)`. Read as a parameter, a base case silently widens a support and
  returns numbers that look entirely reasonable. They are recovered from the
  unevaluated AST instead.

  What a cell answers when nothing is simulating: a draw if a source was given,
  else the base case, else `#VALUE!` — the same refusal `RAND()` makes.

  Two places where the binding is the whole job, both with their own test:

  - **`PsiLogNormal` takes the *arithmetic* mean and deviation** while
    `DistributionLogNormal` takes the underlying normal's, on the log scale.
    Passed through unconverted the median lands at `e^10` instead of 9.806 —
    four orders of magnitude, from a positive and plausibly-shaped number. The
    moments are converted here.
  - **`PsiTriangular` is published `(a, c, b)`** — positionally
    `(min, likely, max)`. The middle argument is the mode, and "correcting" the
    order still produces numbers inside a plausible range.

  `PsiBernoulli` and `PsiBinomial` go through `DistributionDiscrete` and
  `binomialPMF` rather than being written out, so no second implementation of
  anything exists. `PsiBinomial` walks its support accumulating the pmf instead
  of materialising `n + 1` weights, which is why it needs no arbitrary cap on
  `n`.

  Not verifiable against the corpus, and deliberately so: Monte Carlo with no
  published seed means a cached value is one draw from one run. These assert the
  published contract — support, quantile at a known probability, and the idle
  behaviour.

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
See `project/plans/proposals/Excel conformance/excel_function_coverage_matrix.tsv`.

[Unreleased]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.11.0...HEAD
[0.11.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.9.3...v0.10.0
[0.9.3]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.1.0
