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

**`FORECAST.ETS.SEASONALITY` and `FORECAST.ETS.STAT` — and they are NOT a quick win.**
Corrected mid-session after I called them one:

- Excel's `STAT` types 1–3 are the **fitted** α/β/γ. `HoltWintersModel` takes those as
  *constructor arguments* (`init(alpha:beta:gamma:seasonalPeriods:)`), so returning them
  reports an input as a result.
- Nothing upstream **detects seasonality**, which is `SEASONALITY`'s entire job.
- `mae` and `rmse` exist upstream; **MASE and SMAPE do not**.
- The pieces for a fitting routine are all there — `NelderMead` in
  `Optimization/Heuristic`, `HoltWintersModel`, the two error metrics — but wiring them is
  real work and **belongs in BusinessMath**, not the binding layer.

That is the proposal to write next if these are wanted.

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
3. **"Not there" has meant "not there where I looked" six times today.** Every one shrank the
   work. A keyword probe finds free functions and **misses methods on types** — that is how
   three "absent" distributions were miscounted.
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
