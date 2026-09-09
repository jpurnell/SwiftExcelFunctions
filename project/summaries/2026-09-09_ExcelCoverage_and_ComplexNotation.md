# Session Summary: Excel coverage push, and two upstream proposals

| Date | Phase | Status |
| :--- | :--- | :--- |
| 2026-09-09 | Coverage (master plan priority 4) | COMPLETE for this sitting; clean stopping point |

## 1. State at handoff

- **1,042 tests**, 9 skipped, 0 failures. **Gate 45/45 at zero warnings.** Doc coverage 100%.
- Working tree clean but for Justin's Emacs autosave `#PROPOSAL_model_graph_simulation.md#`
  and his deliberate `Excel conformance/` file move (3 tracked deletions, unstaged — his).
- **Excel coverage: 261 `have`, 180 `unreviewed`, 49 `bindable`, 17 `new`, 12 `out of scope`.**
  Started the day at 160/286.
- **Statistical: 2 unreviewed**, from 46. Only `FORECAST.ETS.SEASONALITY` and
  `FORECAST.ETS.STAT` remain.

## 2. What shipped today

Nine new binding files, each with its own test file, all through the same seams:

| File | Functions |
|---|---|
| `BuiltinMathPrimitives` | 20 — hyperbolics, reciprocal trig, `EVEN`/`ODD`, `SQRTPI`, `QUOTIENT` |
| `BuiltinEngineeringFunctions` | 17 — base conversion, bitwise, `DELTA`/`GESTEP`, `ERF` family |
| `BuiltinTextPrimitives` | 12 — `CHAR`, `CODE`, `EXACT`, `TEXTJOIN`, `TEXTBEFORE`/`AFTER`, … |
| `BuiltinStatisticalInverses` | `CHISQ.INV.RT`, `BINOM.INV` |
| `BuiltinStatisticalDistributions` | 8 — the `.DIST` family and the right tails |
| `BuiltinStatisticalQuantiles` | 5 — `BETA.INV`, `GAMMA.INV`, `F.INV.RT`, `T.INV.2T`, `LOGNORM.INV` |
| `BuiltinStatisticalTests` | 7 — `NEGBINOM`, `HYPGEOM`, `WEIBULL`, `CONFIDENCE.NORM`, `Z.TEST`, `CHISQ.TEST`, `F.TEST` |
| `BuiltinCoercingAggregates` | 7 — the `A`-suffixed family |
| `BuiltinSpreadsheetStatistics` | 12 — `.INC`/`.EXC`, `AVEDEV`, `TRIMMEAN`, `STEYX`, `PROB`, `FREQUENCY`, `T.TEST` |
| `BuiltinGammaAndModes` | 9 — `GAMMA`, `GAUSS`, `PHI`, `MODE.*`, `PERMUTATIONA` |
| `BuiltinConditionalExtremes` | 2 — `MAXIFS`, `MINIFS` |

## 3. Immediate next step

**`FORECAST.ETS.SEASONALITY` and `FORECAST.ETS.STAT`. The proposal is written** —
`PROPOSAL_ets_fitting.md`, handed to the BusinessMath session for their tree. **Two of the
four gaps I listed here were not gaps**, found by opening files in the 2.15.0 checkout
(`be704795`) instead of probing keywords:

- `TimeSeries.dominantSeasonLength(maxLag:)` (`Time Series/Diagnostics/Autocorrelation.swift`)
  is **public and already does what `SEASONALITY` does** — strongest ACF lag `h ≥ 2` clearing
  the `1.96/√n` band, `nil` when none clears it. I had written that nothing upstream detects
  seasonality.
- `TimeSeries.mase(against:training:seasonLength:)` **exists**, over `naiveScale`, with
  `BacktestReport` carrying it pooled out-of-sample. I had written that MASE was absent.

What is genuinely absent is a **parameter search** for α/β/γ — `HoltWintersModel` takes them
as `public let` constructor arguments, so returning them today reports an input as a result —
and **SMAPE**, the only metric missing from `STAT`'s eight. Five of the eight are answerable
by code that already exists. `NelderMead` supplies the search.

**Measured against Excel for Mac, 2026-09-09 — the SMAPE convention is settled.** Justin ran
`=FORECAST.ETS.STAT($D$21:$D$32,$C$21:$C$32,$D34,0)` over an alternating `+1, -1` series with
seasonality forced to `0`:

| Statistic | Type | Result |
|---|---|---|
| SMAPE | 5 | **1.94306435** |
| MAE | 6 | 1.040036514 |
| Alpha | 1 | 0.126 |

**Excel uses the halved denominator**, `(|a| + |f|) / 2`, ranging `0-2`. This is decisive
rather than suggestive: the unhalved form is `|a - f| / (|a| + |f|)`, which the triangle
inequality bounds at `1` for every term and therefore at `1` for their mean. A reading of
1.943 cannot be produced by it. MAE at 1.04 against actuals of ±1 confirms the forecasts sat
near zero, which is what makes each term ≈ `1/0.5` = 2.

The alpha reading answers nothing about boundary saturation and that was my design error: I
attached the saturation question to the series built for the SMAPE question, and they need
opposite data. Alpha → 1 is optimal for a *random walk*; an alternating series is maximally
anti-persistent, so a small alpha is correct there. A second attempt
(`10,12,11,14,13,16,15,18,20,19,22,21`) failed the same way — a trend with sawtooth noise,
also mean-reverting — and returned 0.002. **Do not re-run this without a genuinely driftless
walk**, and note that twelve points may be too few regardless, since the trend component
absorbs part of the walk. It does not matter: snapping at saturation was settled on its own
merits, and Excel's answer would only say whether we match in a corner.

One thing the alpha reading does establish: 0.126 is neither the `0.2` library default nor a
boundary, so **Excel genuinely fits alpha** rather than reporting a constant. That validates
the premise behind `STAT` types 1-3.

The Excel side of it stays here: `data_completion`, `aggregation`, timeline step detection
(which is `STAT` type 8 and never reaches a model), the `statistic_type` dispatch, and the
`#NUM!`/`#VALUE!`/`#N/A` mapping — all of Excel's error conditions are timeline conditions
caught before a `TimeSeries` can be built.

## 4. Two proposals filed in BusinessMath — both landed on `main`

Written on `feature/stage-6-template-delegation`; the BusinessMath session cherry-picked them
to `main` and pushed. Verified 2026-09-09 against the GitHub API — every commit below is an
ancestor of `main` and both files are present there. Neither is checked out locally on this
machine: only the SPM checkout at `be704795` exists, which predates the proposals directory,
so reading them means `gh api`.

- `proposals/excel-coverage/PROPOSAL_compatibility_and_lookup.md` (`259c1e70`, `daa7c460`) — the 26 compatibility and
  24 lookup rows. **24 of 26 modern statistical spellings have upstream mathematics**; only
  `CHISQ.TEST` and `F.TEST` were absent, and both are now bound. Eight compatibility rows are
  **not aliases** even once their targets exist — `CHIDIST` is `CHISQ.DIST.RT`, `TINV` is
  `T.INV.2T`, `TDIST` dispatches on `tails`, `BETADIST`/`LOGNORMDIST` are always cumulative.
- `proposals/PROPOSAL_complex_notation.md` (`f06947ea`, `febdf909`, `72242e07` on `main`;
  `1569c8d9`, `11742a90`, `c533869c` as originally written) — a `Complex` ↔ `String`
  codec in `a+bi` notation. **Revised to a member (`notation`, `init?(notation:)`), not a
  `LosslessStringConvertible` conformance** — see §6 there.

## 5. Open decisions

1. **The complex family — 26 rows, not the 21 I first said: 25 `IM*` plus `COMPLEX`.**
   Blocked on the notation codec being *written* in BusinessMath, not on the proposal, which
   has landed. Each binding is then parse → call swift-numerics → format; swift-numerics has
   *all* the mathematics and BusinessMath already depends on `Numerics`.

   **All 26 are `0 calls / 0 books` in the corpus.** This is specification coverage with no
   measured demand behind it, which is the argument for sequencing it after anything the
   corpus does call. `COMPLEX(real_num, i_num, [suffix])` is the only row where a suffix is
   selected, and it selects it by argument — so a canonical `i`-only writer upstream is
   sufficient and the binding swaps the final character. Whether Excel emits a suffix at all
   for a zero imaginary part is a spec question to settle when the binding is written; do not
   assume it.
2. **Lookup's 18 array-returning functions.** Still gated on the array-shape design
   decision — `UNIQUE` and `FILTER` first as the spike, since `HSTACK`/`VSTACK` have
   statically known shapes and would settle nothing.
3. **`consistency` checker at 33% false positives.** Ships opt-in in
   `WorkbookAuditor.experimental` until that comes down.

## 6. Context-loss warnings

1. **`Complex` is not a `Real`, and no wrapper around it becomes one.** It conforms to
   `AlgebraicField`. **Five** sites in BusinessMath constrain on
   `Real & Sendable & LosslessStringConvertible` — `PeriodDriver`, `LinearCycleSolver`,
   `IterativeCycleSolver`, `ModelDefinition` (`Model Definition/ModelDefinition.swift:119`)
   and `FormulaEvaluator` (`Time Series/FormulaEvaluator.swift:140`); I first counted three,
   and the BusinessMath session found the other two. None of them can take a `Complex`, and
   none can take a `ComplexNotation<R>` wrapper either — a wrapper satisfies
   `LosslessStringConvertible` and still fails `Real`. That general form is the point: the
   shape has now been proposed twice and failed the same test both times.
2. **Assert relationships, not remembered constants.** Three tests today failed *correct*
   code because the expected value was recalled rather than read: `ERF(0.745)`,
   `CHISQ.INV.RT(0.050001, 10)`, and a population σ. Round-trips and definitions cannot fail
   that way.
3. **"Not there" has meant "not there where I looked" eight times now.** Every one shrank the
   work. A keyword probe finds free functions and **misses methods on types** — that is how
   three "absent" distributions were miscounted, and how seasonality detection and MASE were
   both written off as missing while sitting public in the tree. The reliable move is to open
   the directory the thing would live in and read it.
4. **The fp-safety checker tracks the divisor *symbol***, not the logical precondition.
   `guard count >= 2` then `/ Double(count - 1)` does *not* satisfy it. Bind the divisor and
   guard the binding.
5. **`MAXIFS` over an empty selection is 0, not `#N/A`** — against the grain of the rest of
   the library. Guessing consistently gets it wrong.
6. **Shared repos: `git commit -- <paths>`, never bare.** BusinessMath and SwiftExcelFunctions
   both have concurrent sessions. A bare commit builds from the whole index and has already
   swept up another session's staged work once.

---

**Next action:** `/recover`, then either the `FORECAST.ETS` fitting proposal (§3) or the
`IM*` family if the complex-notation proposal has landed (§5.1).
