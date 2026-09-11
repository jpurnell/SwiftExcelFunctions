# Changelog

All notable changes to SwiftExcelFunctions will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.7.1...HEAD
[0.8.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.2.0
[0.1.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.1.0
