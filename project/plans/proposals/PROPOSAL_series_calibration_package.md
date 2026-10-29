# Design Proposal — SwiftPathModels, a series calibration and backtest package

**Status:** **WITHDRAWN 2026-10-27 — superseded by BusinessMath.** Kept rather than deleted:
the measurements in §2 and §10 stand and are the reason the residue below is worth anything.
**Date:** 2026-10-23, withdrawn 2026-10-27

---

## 0. Withdrawal — what already existed

The proposal was written without checking BusinessMath beyond its correlation files. Asked to
confirm, the answer is that **most of this is already built, and the parts that overlap are
better than what was proposed**. BusinessMath 3.0.0-alpha.11:

| Proposed here | Already in BusinessMath | Verdict |
|---|---|---|
| `PathModel` protocol with `State` | `StochasticProcess<State>` + `ProcessState` | **superseded** — theirs carries `factors` for multi-factor noise and a continuous `dt`; mine assumed one shock and discrete periods |
| `GeometricBrownian`, future `MeanReverting` | GBM, Ornstein–Uhlenbeck, ABM, GARCH(1,1), Asymmetric GARCH, Heston, Hull–White, **Jump Diffusion**, AR(1), ARMA | **superseded, by a mile** |
| `Period`, `Series` | `Period.swift` (55K), `PeriodArithmetic`, `PeriodSequence`, `PeriodType`, `FiscalCalendar`, `TimeSeries`, `TimeSeriesAnalytics` (47K), `TimeSeriesOperations` | **superseded** |
| `Backtest` harness | `RollingOriginBacktest`, `BacktestReport`, `Baselines`, `ScaledError`, `Forecastability` | **mostly superseded** — see the gap below |
| drift convention / martingale | `MeasureTag` — P and Q as **phantom types**, so pricing under the physical measure is a *compile* error | **superseded, and better than the `Drift` enum proposed in §4** |
| `Correlation` | `CorrelatedNormals`, `CorrelationMatrix`, `MonteCarloEngine` | **superseded** |

§15.1 asked "BusinessMath or a sibling?" and §12 called it "the closest call in the proposal."
It was not close. The answer is BusinessMath, and the question should have been settled by
reading it before writing 468 lines proposing a worse version.

### The residue, which is small and specific

**1. The backtest measures point accuracy, not interval honesty.** `BacktestReport` carries
`rmse`, `mae`, `mape`, `mase` and `residualsByHorizon`. A search of the whole package for
`coverage|exceedance|pinball|quantile loss` returns **one hit**, a doc comment on
`EmpiricalIntervals.confidenceLevel`.

That is exactly the gap §2 measured: the same model, same series, same day, answers "how far off
was the point forecast" acceptably and "did the interval contain the outcome as often as it
claimed" with a **3.7× miss at the 1% tail**.

**And checking BusinessMathPro closes even this.** `Risk/VaR/VaRBacktest.swift` counts
exceptions against predicted VaR and reports `exceptionRate`, a **Kupiec proportion-of-failures
p-value**, and a **Basel traffic light**. That is the measurement of §2 with a proper
significance test on top of it — the error bars there were done by eye, and Kupiec is the test
that should have been reached for.

So the residue is not a gap in the *mathematics*. It is that `BacktestReport` (point accuracy,
in BusinessMath) and `VaRBacktest` (tail exceedance, in BusinessMathPro) are two reports in two
packages answering two halves of one question, and nothing joins them. That is a **composition**
observation, worth a paragraph somewhere, not a package.

**2. `Deck` / `Anchored` / `DeckComparison`.** Anchoring a simulation to a house view, with the
forward strip reported alongside as the neutral baseline. `MeasureTag` and `Baselines` cover
the conceptual half; the composition — deck as centre, measured history as spread — is not
there. Whether it belongs in BusinessMath or in a consumer is an open question, since it is a
modelling application rather than series mathematics.

**3. Correlation stability over subperiods.** ρ moving 0.422 → 0.229 is the finding that makes
a single ρ a choice rather than an estimate. `CorrelationMatrix` computes the statistic;
whether anything reports its stability was not checked.

### What this costs the other proposal

`PROPOSAL_correlated_draws.md` should be re-read against `MonteCarloEngine`, `CorrelatedNormals`
and the **BusinessMathPro** simulation kernel that `StochasticProcess` names as the owner of
"path generation, correlation handling, and Monte Carlo orchestration … called with correlated
normal draws." That proposal argued for building a Gaussian copula over an index vector. If the
kernel already does it, the Risk Solver work is a *binding* to existing machinery rather than
new sampling architecture — which is what the coverage matrix classified `PsiCorrMatrix` as in
the first place.

---
**Scope:** A new sibling package that fits a stochastic path model to a time series and tests
whether the model's intervals are honest. Consumed by ModelSimulator; depends on BusinessMath
and nothing else.

---

## 1. Objective

**Objective:** Measure the parameters a forward-looking simulation needs — volatility, drift,
mean reversion, cross-series correlation — from history, and **test whether the resulting
intervals actually contain the outcome as often as they claim**.

**Master Plan Reference:** none — this is a new package, not a SwiftExcelFunctions feature. It
is proposed here because this is where the need was found and where the consuming work lives.

---

## 2. Motivation

**Current situation.** The Denbury assumptions sheet simulates eight quarters of oil and gas
prices from a recursion whose `sigma` and `rho` were **invented by the author of the sheet**.
A simulation's interval is only as good as that number, and nothing checked it.

**What happened when it was checked.** Against 163 quarters of WTI (EIA, 1986–2026) and 119 of
Henry Hub, the band's coverage was measured at several horizons:

```
WTI  non-overlapping    h1 91.4% ±4.6    h4 87.5% ±9.3    h8 90.0% ±13.1
HH   non-overlapping    h1 90.7% ±5.4    h4 89.7% ±10.9   h8 92.9% ±15.7
                                                      target 90%
```

**And then the band was tested where it matters, which overturned that.** Two-sided 90%
coverage only probes the region where a normal happens to be conservative. The one-sided left
tail — the number a credit model lives on — tells a different story (WTI monthly, realised
exceedances over promised):

```
p=10%   0.5-0.9x        p=5%   0.8-1.0x        p=2%   1.1-2.5x        p=1%   1.6-3.7x
```

At six months the model promises a 1-in-100 downside and delivers 1-in-27. Excess kurtosis of
the log returns is **+7.11 monthly**, +5.51 at quarter-end prints, +3.17 on quarter averages:
the normal is **too wide at 5-10% and too narrow at 1-2%**, which is the fat-tail signature, and
a 90% two-sided test cannot see it.

So the honest statement is narrower than the first one: a one-parameter normal is **adequate for
a P50/P90 revenue range and inadequate for a default tail**, on the same series, at the same
time. Which of those a user is doing decides whether the model is fit for purpose, and the
package has to be able to say so rather than report a single coverage number.

Four things came out of that, and they are the case for the package:

1. **A stated prediction failed, and so did the reassurance that replaced it.** The
   expectation was under-coverage at short horizons and over-coverage at long ones; neither
   appeared, which looked like vindication and was not. The band is right at 90% and wrong at
   99% on the same data. Neither the prediction nor the first conclusion was guessable — both
   had to be measured, and the second needed a *different* measurement to catch.
2. **Two of three invented parameters were nearly right and one was not stable.** σ = 0.15
   against a fitted 0.1518 for WTI; 0.22 against 0.2162 for gas. But ρ measured 0.320 overall
   and moved from **0.422 in the first half to 0.229 in the second** — the post-shale
   decoupling. A single ρ is a choice to defend, not a parameter to estimate, and only
   measurement reveals that.
3. **A single coverage figure is not a verdict.** The same model, same series, same day,
   passes at 90% and fails at 99%. A harness that reports one number would have shipped the
   first answer and hidden the second.
4. **The work was throwaway.** It is a Python script in a scratch directory, and the same
   question recurs for every series anybody would simulate: NGL, power, refining margin, FX, a
   company's revenue line.

**Workaround today:** invent σ, or re-write the script. The first produces confident wrong
intervals; the second produces an answer nobody can reproduce six months later.

**What this is not motivated by.** It is tempting to argue this package should also *fetch*
data. It should not — see §3 and §13.

---

## 3. Proposed Architecture

**A new sibling package**, `SwiftPathModels`, alongside SwiftExcelCore / SwiftXLSX /
SwiftExcelFunctions / BusinessMath.

```
BusinessMath                    (distributions, statistics — already a dependency here)
    └── SwiftPathModels         (new: Period, Series, PathModel, Calibration, Backtest)
            └── ModelSimulator  (imports it to seed and check an assumptions sheet)
```

### The boundary, which is the main decision

**No network, no file formats, no scraping.** The package takes `[(Period, Double)]` and
returns parameters and verdicts. Loaders live outside it.

That line is drawn deliberately, and today's work is why. Prices came from EIA as a clean
40-year series in one HTTP call. Production volumes, which this project also wanted, turn out
not to exist in machine-readable form at all: across Denbury, EOG and Pioneer, SEC XBRL carries
**15, 32 and 2 non-monetary facts respectively** — annual reserve disclosures, not a quarterly
series. Getting production means scraping HTML tables out of earnings releases with a different
layout per company.

A library whose test suite depends on that is a library that fails for reasons unrelated to its
mathematics. So the mathematics is the package and the acquisition is a script.

### New Files

```
Sources/SwiftPathModels/
    Period.swift          calendar period — year + month/quarter, comparable, exact day counts
    Series.swift          an ordered [(Period, Double)]; bucketing, log returns, alignment
    PathModel.swift       the protocol: state, step, level — plus derived path and quantile
    GeometricBrownian.swift   mu, sigma — the model the Denbury sheet uses
    Calibration.swift     fit a model to a series
    Backtest.swift        coverage and tail exceedance, by horizon and by probability
    Correlation.swift     cross-series rho, and its stability over subperiods
    Deck.swift            a house view: a path of central values, no dispersion
    Anchored.swift        deck as centre + fitted model as spread; DeckComparison
Tests/SwiftPathModelsTests/
    Fixtures/wti-quarterly.csv     checked in, so tests are offline and deterministic
    Fixtures/henryhub-quarterly.csv
```

**Module placement:** one module. There is no second concern yet, and splitting a package on
its first day is how two modules end up importing each other.

---

## 4. API Surface

```swift
/// A calendar period, which is the unit a quarterly model actually steps in.
///
/// Exact day counts rather than the 90/91/92 a modeller types by hand — the workbook this came
/// from used 90 for oil and 91 for gas **in the same quarter**, and only a computed count makes
/// that impossible rather than merely unlikely.
public struct Period: Hashable, Comparable, Sendable {
    public enum Span: Sendable { case month, quarter, year }
    public let year: Int
    public let index: Int          // 1...12, 1...4, or 1
    public let span: Span
    public var days: Int { get }   // leap-year correct
    public var next: Period { get }
}

/// An ordered series of observations, one per period.
public struct Series: Sendable, Equatable {
    public let span: Period.Span
    public let observations: [(period: Period, value: Double)]

    public init(_ observations: [(Period, Double)]) throws

    /// Monthly to quarterly by average — what a quarterly revenue model realises, as against
    /// the quarter-end print, which it does not.
    public func bucketed(to span: Period.Span, by rule: Aggregation = .mean) -> Series

    /// Successive log ratios, the input every fit below works from.
    public var logReturns: [Double] { get }

    /// The periods this series and another both cover, for a correlation that is not comparing
    /// two different windows and calling the difference a relationship.
    public func aligned(with other: Series) -> (Series, Series)

    public enum Aggregation: Sendable { case mean, last, sum }
}

/// A model of how a series moves, one period at a time.
///
/// ## The transition is the primitive, not the quantile
///
/// An earlier draft put `quantile(_:horizon:from:)` at the centre and treated paths as a
/// convenience. That was wrong twice over, and both faults have the same root.
///
/// **It assumed the current level is sufficient state.** `from: Double` cannot express a model
/// that carries a variance (GARCH), a regime, or a latent factor — so the API quietly committed
/// the package to one-parameter volatility, which §2 now shows is inadequate for a tail.
///
/// **And it made draws an afterthought** for a package whose main consumer is a Monte Carlo.
///
/// So the primitive is ``step(_:uniform:)``: a state, one uniform, the next state. Paths are
/// iteration. Intervals are either a closed form the model declares or order statistics over
/// simulated paths — and because the harness can always fall back to simulating, **every model
/// is backtestable by the same code whether or not its distribution is analytic.** That is the
/// generalisation the first draft was reaching for and missed.
///
/// ## Why a uniform and not a normal
///
/// A standard normal would bake the marginal into the protocol, which is the same mistake one
/// level down: a Student-t or a jump model wants its own. A uniform in `[0,1)` lets each model
/// apply its own inverse CDF, costs nothing, and — not incidentally — is exactly what
/// `RandomSource.nextUniform()` already serves and what a Gaussian copula correlates. A model
/// that honours **one uniform per step** can be correlated with any other that does, which is
/// the same invariant `PROPOSAL_correlated_draws.md` rests on. The two proposals compose
/// because of it, and neither works if a model takes a variable number.
public protocol PathModel: Sendable {
    associatedtype State: Sendable
    associatedtype Parameters: Sendable & Equatable

    static func fit(to series: Series) throws -> Self
    var parameters: Parameters { get }

    /// The model's state at observation `index`, filtered from everything up to it.
    ///
    /// **This is what makes a stateful model backtestable.** Testing from a historical point
    /// needs the state as it would have been known *then*: for a level-only model that is the
    /// level, for GARCH it is the variance recursion run forward from the start, for a latent
    /// factor it is a filter. Without it a harness can only test models with no memory.
    func state(at index: Int, in series: Series) -> State

    /// One period forward, consuming exactly **one** uniform in `[0,1)`.
    func step(_ state: State, uniform: Double) -> State

    /// The observable value of a state.
    func level(of state: State) -> Double

    /// A closed form, where the model has one. `nil` means the harness simulates instead —
    /// correct either way, exact when available.
    func quantile(_ probability: Double, horizon: Int, from state: State) -> Double?
}

extension PathModel {
    /// One path. The primitive, iterated.
    public func path(from state: State, periods: Int,
                     using source: inout some RandomNumberGenerator) -> [Double]

    /// The quantile, analytic if the model has one and simulated if it does not.
    public func quantile(_ probability: Double, horizon: Int, from state: State,
                         paths: Int = 10_000, seed: UInt64) -> Double
}

/// Log price is a random walk with drift. Closed-form quantiles; no simulation needed.
public struct GeometricBrownian: PathModel {
    public struct Parameters: Sendable, Equatable { public let mu, sigma: Double }
    /// Drift conventions, because this is a choice and not a measurement.
    public enum Drift: Sendable {
        case fitted          // the sample mean log return
        case zero            // flat median path
        case martingale      // -sigma^2/2, so the *mean* is flat; futures-consistent
        case explicit(Double)
    }
    public static func fit(to series: Series, drift: Drift = .martingale) throws -> Self
}

/// Log price reverts to a long-run level. Schwartz one-factor.
public struct MeanReverting: PathModel {
    public struct Parameters: Sendable, Equatable {
        public let kappa, theta, sigma: Double
        /// ln(2)/kappa — the half-life, which is the parameter a person can actually judge.
        public var halfLifeInPeriods: Double { get }
    }
}

/// Did the interval contain the outcome as often as it claimed?
public struct Backtest: Sendable {
    public struct Coverage: Sendable, Equatable {
        public let horizon: Int
        public let inside: Double          // share within the band
        public let below, above: Double    // which tail the misses fell in
        public let samples: Int
        public let windows: Windows
        /// ±1.96 standard errors. **Non-overlapping only** — see the note on `Windows`.
        public var marginOfError: Double? { get }
    }

    /// How start points were chosen.
    ///
    /// `.overlapping` uses every period as a start, which keeps the estimate unbiased and makes
    /// the error bar meaningless: an eight-quarter window shares seven quarters with the next
    /// one. `.nonOverlapping` is what an honest ± can be quoted from, at the cost of n.
    /// Both are reported because each answers a different question.
    public enum Windows: Sendable, Equatable { case overlapping, nonOverlapping }

    public static func coverage<M: PathModel>(
        of model: M, over series: Series,
        horizons: [Int], interval: ClosedRange<Double> = 0.05...0.95,
        windows: Windows = .nonOverlapping
    ) -> [Coverage]
}

/// Somebody's view of where a series is going: a path of central values, no dispersion.
///
/// A house deck is not a distribution and must not be treated as one. Substituting GS's numbers
/// for a simulated path puts back exactly the point estimate a simulation exists to remove.
public struct Deck: Sendable, Identifiable {
    /// Whose view, and as of when — both, because a deck without a date is not comparable.
    public let id: String                       // "GS Commodity Research, 2026-10"
    public let values: [(period: Period, value: Double)]
}

/// A deck supplies the **centre**; a fitted model supplies the **spread**.
///
/// This is the decomposition that makes "swap in Morgan Stanley's view" a one-line change and
/// makes the comparison meaningful: hold the dispersion fixed, change the anchor, and the
/// difference in the output distribution *is* what the view is worth.
///
/// **Two things a user of this should be told rather than left to infer.**
///
/// A bank deck is not a martingale. GS at $80 when the strip is $65 is a claim that the market
/// is wrong; anchoring there while keeping a market-calibrated sigma asserts "their level, the
/// market's uncertainty", which is coherent and specific and worth saying out loud.
///
/// And a bullish anchor mechanically improves every credit metric, because it lifts the whole
/// distribution including its fifth percentile. So ``DeckComparison`` always reports the
/// forward strip alongside, as the neutral baseline a reader can subtract.
public struct Anchored<Dispersion: PathModel>: PathModel {
    public let deck: Deck
    public let dispersion: Dispersion
    /// Whether the deck is the median or the mean of the simulated paths. They differ by
    /// `exp(sigma^2 h / 2)`, which is the same choice `GeometricBrownian.Drift` makes and the
    /// same one that quietly added 6% to a flat-price assumption.
    public enum Centre: Sendable { case median, mean }
    public init(deck: Deck, dispersion: Dispersion, centre: Centre = .median)
}

/// The same company model under several views, with the market alongside.
public struct DeckComparison: Sendable {
    public struct Row: Sendable {
        public let deck: Deck.ID
        public let metric: Double          // whatever the caller measured
        public let versusStrip: Double     // the part attributable to the view
    }
    public let rows: [Row]
    /// Always present, never optional: without it the table reports a house's optimism as if it
    /// were a property of the company.
    public let strip: Row
}

/// Cross-series dependence, and whether it holds still.
public struct Correlation: Sendable {
    public let rho: Double
    public let samples: Int
    /// The same statistic over equal subperiods. A ρ that moves from 0.42 to 0.23 is not one
    /// number, and reporting only the average would hide that.
    public let bySubperiod: [Double]
    public static func between(_ a: Series, _ b: Series, subperiods: Int = 2) -> Correlation
}
```

---

## 5. MCP Schema

**Tool Description:** Fit a path model to a series and report whether its intervals hold up.

```json
{
  "series": {"span": "quarter", "observations": [["1986Q1", 22.93], ["1986Q2", 13.44]]},
  "model": "geometricBrownian",
  "drift": "martingale",
  "horizons": [1, 2, 4, 8],
  "windows": "nonOverlapping"
}
```

**Parameter Types:**
- `series.span` (string): `month` | `quarter` | `year`.
- `series.observations` (array): `[period, value]`, period as `YYYYQn` / `YYYY-MM` / `YYYY`.
- `model` (string): `geometricBrownian` | `meanReverting`.
- `drift` (string): `fitted` | `zero` | `martingale` | a number.
- `horizons` (array of integer): periods ahead to test. Each must be < the series length.
- `windows` (string): `overlapping` (tighter estimate, no usable error bar) or
  `nonOverlapping` (honest ±, fewer samples).

**Returns:** parameters, and one coverage row per horizon with `inside`, `below`, `above`,
`samples` and `marginOfError`.

---

## 6. Constraints & Compliance

**Concurrency:** every type is an immutable `Sendable` value. `fit` and `coverage` are pure.

**Determinism:** `path(from:periods:using:)` takes the generator `inout`, so a seeded run
reproduces. Nothing else is random.

**Generics:** `PathModel` is a protocol with an associated `Parameters`; `coverage` is generic
over it rather than switching on a model enum.

**Division safety:** log returns guard against a non-positive observation — a price series with
a zero in it is a data error, and `log(0)` reported as `-inf` would propagate into σ silently.
`Series.init` rejects it.

**Safety:** no force unwraps. `horizon` is validated against series length; a horizon longer
than the data throws rather than returning a coverage over zero samples.

**No network, ever** — see §3. This is a compliance point, not just a design one: it is what
keeps the test suite deterministic.

---

## 7. Source & API Compatibility

**Breaking changes:** none anywhere. Entirely new package, no existing callers.

**Incremental adoption:** ModelSimulator can import it without changing anything else, and
nothing in SwiftExcelFunctions needs to know it exists.

**Type-checking risk:** N/A — new API with no existing surface to overload.

---

## 8. Backend Abstraction

Not applicable, and the numbers say why rather than leaving it to judgement. A fit is one pass
over the log returns; a coverage test is `horizons × samples` closed-form quantile evaluations.
The whole WTI backtest above — 163 quarters, five horizons, both window modes — ran in well
under a second in interpreted Python. There is nothing here to accelerate.

---

## 9. Dependencies

**Internal:** none.

**External:** BusinessMath, for the normal quantile and the descriptive statistics. Already a
dependency of this family, already resolved, and the alternative — hand-rolling `Phi^-1` — is
the duplication this family keeps refusing.

**Deliberately not depended on:** SwiftXLSX, SwiftExcelFunctions, Foundation networking. A
series does not need to know what a spreadsheet is.

---

## 10. Test Strategy

**Test categories**

- **Golden path:** the measurements taken today, from a checked-in fixture.
- **Period arithmetic:** day counts per quarter including leap years; `next` across a year end.
- **Bucketing:** monthly → quarterly by mean, and the refusal of a partial quarter.
- **Alignment:** two series over different windows intersect to the common periods only.
- **Drift conventions:** `martingale` gives a flat *mean*; `zero` a flat *median*. These differ
  by `exp(sigma^2 h/2)` and conflating them is how a flat-price assumption became a 6% lift.
- **Windows:** `nonOverlapping` yields `floor(n/h)` samples and a finite margin;
  `overlapping` yields `n-h` and `nil` margin, because an error bar there would be a lie.
- **Edge cases:** horizon ≥ series length throws; a zero or negative observation is rejected;
  a two-point series fits but cannot be backtested.
- **Model comparison:** GBM and MeanReverting both fit WTI and both backtest, demonstrating the
  protocol does its job.

**Reference truth**

EIA series `RWTC` (Cushing WTI spot, monthly) and `RNGWHHD` (Henry Hub spot, monthly),
downloaded 2026-10-23, bucketed to quarterly means. Independently verifiable: the files are
public at `eia.gov/dnav/pet/hist_xls/RWTCm.xls` and the fixture is a CSV extract of them.

**Validation trace (required)** — every figure below was computed today, not recalled:

| Assertion | Expected |
|---|---|
| WTI quarterly log-return σ, 1986Q1–2026Q3, n=163 | **0.1518** |
| WTI mean quarterly log return | **+0.0101** |
| Henry Hub σ, 1997Q1–2026Q3, n=119 | **0.2162** |
| WTI coverage, σ=0.1518, h=1, non-overlapping | **91.4%**, n=162 |
| WTI coverage, h=8, non-overlapping | **90.0%**, n=20 |
| WTI tail split at h=4 | **5.0% below / 5.0% above** |
| Henry Hub coverage, h=8, non-overlapping | **92.9%**, n=14 |
| oil–gas ρ, quarterly log returns, 1997–2026, n=118 | **0.320** |
| ρ first half / second half | **0.422 / 0.229** |
| WTI monthly σ, n=488 | **0.0973** |
| excess kurtosis — monthly / quarter-end / quarter-avg | **+7.11 / +5.51 / +3.17** |
| WTI monthly left-tail exceedance at p=1%, h=6, non-overlapping | **3.70% (3.7× promised)** |
| WTI monthly left-tail exceedance at p=5%, h=6 | **4.94% (1.0× promised)** |
| empirical vs normal 1st percentile of monthly log return | **−0.3067 vs −0.2262** |

The last three are the ones that matter most, because they are the assertions that fail if
somebody later "simplifies" the harness to report a single coverage number. A test suite that
only pins 90% coverage would pass a model this package has measured to be wrong.

The σ figures are the sharpest: they are a single statistic over a fixed window and must
reproduce exactly, not within a tolerance. The coverage figures are counts over the same fixed
window and must also reproduce exactly — there is no sampling in this test, only arithmetic.

---

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `project/decisions/architecture_decisions.md` — ADR-001 (Excel is the
      specification), ADR-002 (byte functions), ADR-003 (zero-snap).
- [x] Supersede an existing ADR? **No** — none of the three concerns a sibling package.
- [x] Amend an existing ADR? **No.**
- [x] New ADR required? **No**, and deliberately. The one decision worth recording — that the
      package takes data and never fetches it — belongs in this package's own decisions log
      once it exists, not in SwiftExcelFunctions'. Filing it here would put a decision about
      another package in this one's history.

---

## 12. Adversarial Review

**Strongest case for a different approach**

Put all of it in **BusinessMath**. It already owns distributions, correlation and descriptive
statistics; `Phi^-1` is there; a new package is another thing to version, tag, pin and
reconcile, and this family has five of those already. A reviewer would say the marginal content
here is a few hundred lines of statistics and two value types, and that the honest home for a
few hundred lines of statistics is the statistics package.

That argument is strong enough that it may be right. The counter is that `Period`, `Series` and
`Backtest.Windows` are **domain modelling**, not mathematics — BusinessMath has deliberately
stayed free of calendars — and that a backtest harness carries methodology opinions (which
window scheme, which tail reporting) that a general math library should not be asserting.

**Where this design is most likely wrong**

The load-bearing assumption is that **a one-parameter volatility is the right abstraction**.
Today's measurement supports it for quarterly-average prices to eight quarters, and that is a
narrow window dressed up as a validation: it says nothing about monthly data, nothing beyond two
years, and nothing about a series with a structural break. Building `PathModel` around
"quantile at a horizon" bakes in that a horizon is all you need to know — which is false for any
model with a state variable beyond the current level (stochastic vol, regime switching).

The constraint accepted without much challenge: that the consumer wants *intervals*. A user
calibrating for a Monte Carlo wants draws, and `path(from:periods:using:)` is an afterthought
in this API rather than its centre.

**What an experienced critic would say**

> "You validated one model on two series over one window, and the proposal that follows is a
> framework with a protocol, two models and a harness. That is a lot of architecture resting on
> h≤8 quarterly averages."

Proceeding, with the scope narrowed in response: `MeanReverting` moves to §14 as a future
direction rather than a shipped model, because nothing measured so far needs it — gas at h=8 is
the only hint and it is inside its own error bar. Shipping one model and a protocol is enough to
prove the protocol is not a fiction; shipping two, when one is unmotivated, is the framework the
critic is describing.

**Both earlier objections in this section turned out to be the same fault, and both are now
fixed rather than noted.** The draft above recorded that "the consumer wants intervals" had been
accepted without challenge, and separately that the design assumed one-parameter volatility.
They are one problem: `quantile(_:horizon:from: Double)` takes the *level* as sufficient state,
which simultaneously makes draws secondary and makes a variance, a regime or a latent factor
inexpressible. Rebuilding the protocol on ``step(_:uniform:)`` answers both — and then the tail
measurement in §2 showed the one-parameter assumption is not merely a theoretical limit but
wrong by 3.7× where it is used for credit.

That sequence is the argument for writing this section at all: the objection was recorded before
the evidence existed, and the evidence arrived a day later.

**Where the design is now most likely wrong.** `state(at:in:)` assumes a model's state is
recoverable from the series alone. That holds for a level, and for GARCH where the variance
recursion is deterministic given a seed value. It does not hold for a genuinely latent factor,
where the state is a *distribution* rather than a value and backtesting from a point requires a
filter whose own uncertainty the harness would be ignoring. The protocol admits such a model
syntactically and would mis-test it, which is worse than refusing it.

---

## 13. Alternatives Considered

**Alternative 1 — a module inside BusinessMath.**
- Advantage: no new package; `Phi^-1` and friends are already there; one fewer thing to pin.
- Disadvantage: puts calendars and methodology into a general math library.
- Why not: see §12. This is the closest call in the proposal and is listed first for that
  reason. **If the answer is "fold it in", the API above survives nearly unchanged** — it would
  become `BusinessMath/Series/`, and the cost of being wrong here is a move, not a rewrite.

**Alternative 2 — keep it a script.**
- Advantage: it already works; zero API surface; nothing to maintain.
- Disadvantage: unreproducible six months out, untested, and Python in a Swift stack.
- Why rejected: the parameters it produces go directly into models people act on. That is the
  last thing that should live in a scratch directory — and this one already measured that two
  invented parameters were lucky and a third was unstable, which is exactly the finding a script
  nobody runs again would have lost.

**Alternative 3 — include the data loaders (EIA, SEC).**
- Advantage: one import, end to end, which is what a user actually wants.
- Disadvantage: binds a mathematics library to HTTP, to two agencies' formats, and — for
  production volumes — to per-company HTML scraping. The test suite stops being deterministic.
- Why rejected: see §3. The loaders are worth having and belong beside the package, not inside
  it. A thin `SwiftPathModelsEIA` is a reasonable second package once there is a second caller.

**Alternative 4 — generalise to any `Collection<Double>` and drop `Period`.**
- Advantage: smaller; works on anything; no calendar code.
- Disadvantage: loses the day count, which is the thing that caught a real error in the Denbury
  template, and makes `aligned(with:)` impossible — you cannot intersect two series on period if
  they have no periods.
- Why rejected: the calendar is doing work.

---

## 14. Future Directions

- **Mean reversion** (`MeanReverting`), if a horizon beyond two years or a faster-reverting
  series ever needs it. The protocol is shaped to accept it without changing the harness.
- **A loader package** for EIA, once something other than this needs one.
- **Seasonality**, which gas plainly has and this ignores entirely.
- **Parameter uncertainty** — σ is itself estimated, and a band that ignores that is slightly
  too narrow. Reporting a confidence interval on σ could feed a second layer of draws.
- **A fat-tailed marginal** — Student-t on the shock, or a jump component. No longer
  speculative: §2 measures excess kurtosis of +7.11 and a 1% tail missed by 3.7×. The protocol
  takes a uniform precisely so a model can apply its own inverse CDF, so this is a new
  conformance rather than a change to the harness. **Deliberately not in scope now**: fitting a
  tail index on 488 observations is a different kind of estimation problem, and shipping it
  without its own validation would repeat the mistake this proposal exists to document.
- **Backtesting the decks themselves.** If dated house views are kept, the same harness measures
  whether GS or MS beat the forward strip, or beat no-change. The published literature generally
  finds oil forecasts — including the futures curve — struggle to beat a random walk; this would
  turn "presumably they are smart" into a number, for these decks, on this series.

---

## 15. Open Questions

1. **BusinessMath or a sibling?** §12 and §13 both lead here and it is the question to settle
   before any code. The API is nearly identical either way, so this is a packaging decision, not
   a design one — but it is the user's to make.
2. **The name.** `SwiftPathModels` describes the contents; it is cheap to change now and
   expensive after a tag exists.
3. **Does production data ever arrive?** Measured today: SEC XBRL carries 15 / 32 / 2
   non-monetary facts for Denbury / EOG / Pioneer — no quarterly volume series exists in
   structured form. If prices are the only series this is ever used on, Alternative 2 deserves
   another hearing, because a package serving one caller on one data type is a file of functions
   with a version number.
4. ~~**Intervals or draws?**~~ **Resolved by rebuilding the protocol on the transition** —
   see §4 and §12. Draws are the primitive; intervals are derived, analytically where a model
   has a closed form and by simulation where it does not.
5. **What does the backtest report by default?** The measurements say a single coverage number
   is misleading, so the default should be a grid — horizons × probabilities — and the question
   is whether the package should also return a *verdict* ("adequate for a median, not for a
   tail") or leave that to the reader. A library that grades its own output is overstepping; one
   that reports a grid nobody reads correctly is not much better.
6. **How is a deck obtained?** `Deck` is a value type with no loader by §3's rule, which is
   right for the mathematics and leaves the practical question open: house decks arrive as PDFs
   and emails, and the forward strip needs CME data. Possibly a `Deck` is simply typed in, which
   is fine and should be said rather than discovered.
7. **Does `Anchored` belong here at all?** It is arguably a modelling *application* rather than
   series mathematics, and the package's own §3 boundary could be read as excluding it. Kept in
   because the alternative — every consumer re-deriving "deck as centre, history as spread" —
   is the duplication §13 Alternative 2 warns about.
