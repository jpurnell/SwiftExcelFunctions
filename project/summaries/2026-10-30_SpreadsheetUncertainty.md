# Spreadsheet uncertainty — a model that spans sheets, and four plausible wrong numbers

**Written:** 2026-10-30
**Covers:** one long session across **three repositories** — SwiftXLSX, SwiftExcelFunctions and
the ModelSimulator app — from "why can't I run the model when I immediately open it" to a
notarised app simulating a 1990s Goldman E&P template across four sheets.

| Date | Phase | Status |
| :--- | :--- | :--- |
| 2026-10-30 | Simulation, consumed by a real application | COMPLETED — nothing half-finished |

---

## 1. Core objective

Make an **arbitrary Excel model** sensitisable: put uncertainty through a workbook somebody
else wrote, without rebuilding it. That framing was settled late in the session and is worth
recording, because it decides which of two stacks the work belongs to — see §6.

## 2. What happened

The session began with a usability complaint and ended three releases later, because every fix
uncovered a defect underneath it. The arc:

1. A freshly-opened model would not run. Run required a distribution before it would light up,
   withholding the check anybody sensible makes first.
2. Making it run meant collecting outputs by default, which turned the first run into an audit
   of the whole model against the values Excel wrote into the file.
3. **That audit immediately failed on the first real workbook** — 19 of 21 outputs reading
   `0.000` against a workbook holding `102,852` — and the rest of the session was chasing why.

## 3. The through-line, which is the thing to remember

**Every defect found was a plausible wrong number, not a crash.** Four of them, in four
different places:

| Where | What it did | Found by |
|---|---|---|
| ModelSimulator | read one sheet, answered questions about every other sheet with that sheet's cells | the static check, on the first real workbook |
| ModelSimulator | handed other sheets' formulas back unevaluated, so arithmetic collapsed to zero | the same check, after the first fix was not enough |
| SwiftExcelFunctions | implicit intersection never reached a function argument, so `VLOOKUP($C$6:$C$8, …)` was `#N/A` | the same check again |
| SwiftXLSX | `LOG10(x)` parsed as a call on **column LOG, row 10** — round-tripped through files unchanged and evaluated to `#VALUE!` | 300 cells of one workbook, all silently zero |
| SwiftExcelFunctions | `Swift.max(0, .nan)` is `0`, so `AMORDEGRC` reported a depreciation for an asset it could not compute | the quality gate, six weeks after the code was written |

None would have announced itself in use. That is the failure class this family of packages
exists to catch, and it was producing it.

## 4. Releases

| Package | Version | What |
|---|---|---|
| SwiftXLSX | **0.37.2** | `LOG10` is a function, not a cell. A reference followed by `(` is a function name; Excel has no syntax for calling a cell's contents, so nothing is traded away. 942 tests in 55 suites, plus 8 new. |
| SwiftExcelFunctions | **1.0.0-alpha.4** | Implicit intersection reaches the lookup family's first argument; both run engines pass the cell being evaluated, having passed `at: nil` and so switched the rule off for every simulation. 1,928 tests. |
| SwiftExcelFunctions | **1.0.0-alpha.5** | **A run spans sheets.** `CellAddress` through `ModelSurvey`, `SimulationRun`, `DistributionOverride` and both engines — breaking, which is what the alpha is for. 1,933 tests. |
| ModelSimulator | **0.1.0** | Notarised, in `/Applications`. |

### The one worth re-reading

alpha.5's per-trial overlay had been keyed by **position alone**, so an override computed for
`Model!B4` would have been handed to a formula asking for `Pricing!B4`. No error, a completed
run, statistics about a model that never existed. Unreachable only while a run could not leave
its sheet.

Folding the sheet name for those keys then leaked a lower-cased name back to a provider, which
looked for `model` in a workbook holding `Model` and read every constant there as blank. The
interpreted engine was right by accident and the parallel one was not; **the two disagreeing is
how it was found**, which is the argument for keeping both.

## 5. Measurements

Taken against EIA series `RWTC` and `RNGWHHD`, downloaded 2026-10-23. Fixtures are not in the
repo; the series are public.

| | Invented | Measured |
|---|---|---|
| WTI σ / quarter | 0.15 | **0.1518** |
| Henry Hub σ / quarter | 0.22 | **0.2162** |
| oil–gas ρ | 0.35 | **0.320** — and unstable, 0.422 then 0.229 |

Two-sided 90% coverage is honest at every horizon to two years, non-overlapping. **That is not
validation**, and believing it was is the mistake this session nearly shipped: the one-sided
left tail at p=1% is missed by **3.7×**, excess kurtosis is **+7.11** monthly, and the normal
is too wide at 5–10% while being too narrow at 1–2%. A 90% two-sided test only probes the
region where the error is conservative.

**So the same model is adequate for a revenue range and inadequate for a default tail, on the
same series, on the same day.** That distinction is the headline finding.

## 6. Design decisions

- **Decision:** the spreadsheet stack is for models you did not write.
  **Rationale:** BusinessMath + BusinessMathPro already model natively — `StochasticProcess`,
  eleven processes including Heston and JumpDiffusion, `RollingOriginBacktest`, `VaRBacktest`
  with Kupiec and Basel traffic lights, `CashFlowAtRisk`, `CapitalStructureProjection`, and a
  `SimulationKernel` that builds the Cholesky factor. The Denbury *credit* question is already
  a first-class citizen there.
  **Alternative rejected:** rebuilding any of it here. One proposal was withdrawn for exactly
  this reason — see §8.

- **Decision:** evaluate only the precedent closure of the outputs.
  **Rationale:** measured — 2,000 trials went **216.4s → 37.4s, 5.8×**. Deliberately late
  rather than early; the guessed figure was 40× and the doc comment records both.

- **Decision:** a setup is keyed by workbook **path**, not a security-scoped bookmark.
  **Rationale:** a moved workbook loses its setup, which costs a minute. A stale bookmark
  resolves to a file nobody opened, which does not announce itself.

## 7. Quality gate

```
SwiftExcelFunctions   49 of 49 checkers · 0 errors · 0 new findings gating · 1,957 tests
SwiftXLSX             46 of 46 checkers · 0 warnings · 942 tests in 55 suites
ModelSimulator        65 tests, 1 skipped, 0 failures
```

## 8. Proposals, both tracked and neither approved

- **`PROPOSAL_correlated_draws.md`** — `PsiCorrMatrix` and friends over the `inputIndex`
  vector. Narrowed twice by measurement: **no corpus workbook declares correlation at all**
  (0 calls, 0 books, over a census that read 2,236 of 2,283), so the fidelity argument was
  retracted; and BusinessMathPro's kernel already does the Cholesky and the PSD refusal, so
  what survives is the integration, not the mathematics.
- **`PROPOSAL_series_calibration_package.md`** — **WITHDRAWN**, superseded by BusinessMath,
  kept because the measurements stand. §15.1 asked "BusinessMath or a sibling?" and §12 called
  it the closest call in the proposal. It was not close.

## 9. Exact next step

**Take a deliberate pass at `fallback.clamp-absorbs-nan`.** The rule is new and clustered
**326 occurrences**; two were gating and were fixed in `71eac63`. The remaining **324 sit
behind the baseline with expiry dates**, so they will surface two at a time whenever one
lapses — each time blocking an unrelated commit, as they blocked this session's proposals.

```bash
cd SwiftExcelFunctions
quality-gate 2>&1 | grep -A3 "clamp-absorbs-nan"
```

It is the same failure class as §3 and it is already in the codebase.

## 10. Decisions needed, not blockers

1. **Approve or reject the two proposals.** Both are Phase 0 and neither has a verdict.
2. **The 1% tail.** Revenue ranges from the Denbury model are honest; a credit conclusion is
   not. Either a fat-tailed marginal — BusinessMath has `JumpDiffusion` — or a standing rule
   that this tool reports P10 and never a probability of distress.
3. **Production data.** Prices are calibrated against 40 years; the growth rates in the
   Denbury Assumptions sheet are **invented**, so that is where the model risk now sits. SEC
   XBRL cannot supply it: Denbury, EOG and Pioneer carry 15, 32 and 2 non-monetary facts
   respectively — annual reserve disclosures, not a quarterly series.

## 11. Environment notes worth carrying

- **1,932 of 2,285 corpus workbooks under `~/Documents` are evicted iCloud placeholders.** A
  scan stalls at 0% CPU pulling them down one at a time; this is also what caused the census's
  43 timeouts. `brctl download` **no longer exists** on macOS 27 — its commands are `accounts
  diagnose dump log monitor status`. "Keep Downloaded" has no CLI at all, and
  `optimize-storage = 1` is set, so anything materialised is re-evictable. The durable fix for
  a test corpus is moving it out of iCloud-synced `~/Documents`.
- **A Developer ID certificate expired on 2026-10-28** during this session. Two remain.
  `ModelSimulator/scripts/release.sh` names its identity **by SHA-1 hash** rather than by name
  for this reason — three certificates shared one common name, and signing by name is a coin
  flip. Anything else on this machine signing by name has the same exposure.
- `git rev-list origin/main..HEAD` was twice reported from a **stale remote-tracking ref**,
  producing a phantom "1 unpushed commit" that was already merged via PR #1. Fetch first.
