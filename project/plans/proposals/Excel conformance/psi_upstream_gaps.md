# The Psi delta — what is missing after BusinessMath 2.14.0, and whose it is

**Measured** 2026-09-07 against BusinessMath `v2.14.0`. Joinable data: `psi_upstream_gaps.tsv`.

BusinessMath 2.14.0 closed its Risk Solver work list — **49 rows, all done**. This file records
what that work list did not cover, because nothing upstream does.

---

## Why there is a delta at all

The upstream work list was scoped **from the corpus**: 49 rows chosen because real workbooks call
them. That was the right scope and it succeeded — every Psi distribution the corpus uses is now
backed. The delta is everything Frontline documents that our corpus happens not to call.

**The two lists do not overlap at all.** Of the 57 distribution names with no upstream
mathematics, **zero** appear in `businessmath_work.tsv`. This is not work that was attempted and
missed; it is work that was never in scope, and no document upstream tracks it.

Two of the 57 are half-recorded, in prose rather than as rows — `businessmath_work.tsv`'s notes on
`PsiAR1` and `PsiGARCH11` say the other seven time-series functions "follow the same pattern and
should share one implementation." True, and not a tracking mechanism.

---

## The delta, by owner

| Group | Rows | Owner | What it needs |
|---|---:|---|---|
| Percentile parameterisation (`*Alt`) | 28 | BusinessMath | **One** fitting solve, not 28 distributions |
| Individual distributions | 17 | BusinessMath | Genuinely absent mathematics |
| Time series | 7 | BusinessMath | Two family implementations |
| Not mathematics | 5 | **Ours** | Name resolution, not computation |

**52 of 57 are BusinessMath's — but they are not 52 pieces of work.** They collapse to roughly
**twenty**: one percentile-fitting capability covering 28 rows, two process families covering 7,
and seventeen individual distributions.

### The 28 `*Alt` rows are one capability

`PsiNormalAlt`, `PsiWeibullAlt`, `PsiParetoAlt` and the rest are not new distributions. They are
the *same* distributions parameterised differently — the signature reads "2 parameters: 2
different percentiles, or percentile and mean, or percentile and stdev". Given a distribution with
a quantile function, solving for the parameters that hit stated percentiles is one root-find
against `quantile`, reusable across every conformer.

Sized as 28 rows this looks like the largest block in the delta. Sized as work it is the smallest,
and doing it as 28 separate implementations would be the expensive mistake.

### The 5 that are not BusinessMath's

`PsiSip`, `PsiSlurp`, `PsiTSSip`, `PsiCertified` and `PsiVary` take the *name* of a stored data
object — a Stochastic Information Packet held in the workbook — or declare a sensitivity role.
Nothing is computed; a name is resolved against the file.

That is address arithmetic, and BusinessMath's own proposal already draws this line for
`INDIRECT`, `OFFSET` and `ADDRESS`: "they are error semantics and address arithmetic.
BusinessMathExcel owns them." These belong with `solver_adj` and the Psi role declarations, read
from the sheet rather than evaluated.

**Do not ask upstream for these.** They would have to invent a workbook to satisfy them.

---

## What this does *not* block

Nothing the corpus reaches. All nine Psi distributions our 2,236 workbooks actually call —
`PsiBernoulli`, `PsiNormal`, `PsiLogNormal`, `PsiTriangular`, `PsiDiscrete`, `PsiUniform`,
`PsiBinomial`, `PsiIntUniform`, `PsiPoisson` — are backed by 2.14.0 and bindable today. They cover
1,166 of the family's 1,950 corpus calls.

Of the 57 in this delta, the corpus calls **none**.

So this is a completeness list, not a blocker list, and it should be sized that way. Per the
master plan's own standing rule: full coverage is not a prerequisite for the work that is
corpus-shaped.

---

## What is left, after BusinessMath 2.15.0

2.15.0 implemented the whole 52-row delta this document was written to record, and adopted the
proposal's shape: `PercentileParameterisable`, `ParameterConstraint`, `fitting(_:)`. **104 of 113
distribution rows are now bound.** Nine remain, in three groups.

### Not mathematics — ours, and not a gap upstream (5)

`PsiSip`, `PsiSlurp`, `PsiTSSip`, `PsiCertified`, `PsiVary`. Each names a stored data packet in
the workbook or declares a sensitivity role; nothing is computed. Address arithmetic, which
upstream's own proposal assigns downstream. These belong with `solver_adj` and the role
declarations, read from the sheet rather than evaluated.

### Bound nowhere, because the argument's meaning is unstated (1)

| Function | What is unresolved |
|---|---|
| `PsiMakeInput` | `(freq, expr, deduct, limit)` builds a compound frequency/severity model, and `CompoundLossModel` takes `Frequency` and `Severity` *distributions*. A cell value cannot carry a distribution, so either Frontline's `freq`/`expr` are references the host resolves, or `expr` is a spreadsheet expression evaluated per occurrence. Both are host semantics rather than mathematics — BusinessMath reached the same conclusion independently. |

**`PsiMetalogFit` and `PsiMetalog2Fit` are now bound**, and did not need the answer they
appeared to need. Frontline does not say which of `x_values`/`y_values` carries the probability
— but a fitting probability is *defined* as strictly inside `(0, 1)` and distinct, and
`DistributionMetalog` enforces exactly that. So the vector is identified rather than assumed:
whichever satisfies the definition, is it, in either argument position.

Where **both** vectors could be probabilities — a market-share or utilisation model does this —
the call is genuinely ambiguous and is refused. Fitting the transpose would return a number that
looks entirely reasonable and that nothing downstream could question.

### One waiting on a tag (1)

`PsiAPARCH11`. BusinessMath added `AsymmetricPowerArch.init(name:unconditionalVolatility:…)` on
`main` and it ships in 2.16.0; this binds the moment that tag lands.

The derivation turned out **not** to be distribution-circular, which is what I had wrongly
concluded: `ω = σ^δ(1 − ακ − β)` where `κ = E(|z| − γz)^δ` is an expectation over the
*innovation*, depending on γ and δ alone and not on ω, so it is computable before the
distribution exists. At γ = 0, δ = 2 it collapses to `ω = σ²(1 − α − β)`, which is why the GARCH
case worked and this one looked harder than it was.

So Frontline's second argument **is** a volatility and its name was accurate throughout.

## Corrections to the matrix itself, 2026-09-08

Three, found by running the recognizer against real workbooks rather than by reading the file.
Recorded because the *kind* of error matters: none would have failed a test, and two would have
produced plausible numbers.

### `PsiTarget` was recorded backwards — and the first correction was also wrong

The matrix gave `FinancialSimulation.probabilityAbove`. Frontline's own page is explicit:

> Both functions return the proportion of simulated values for cell that are **less than or equal
> to target value**.

So it is P(X ≤ value), not P(X ≥ value). Corrected — and then corrected again, because
`probabilityBelow` is not right either. It counts strictly:

```swift
if try metric(projection) < threshold { belowCount += 1 }
```

Frontline says *or equal to*. On a continuous output that difference is measure-zero and
invisible. On a discrete one it is the entire probability mass at the boundary — and
`PsiBernoulli` is 55 of 314 measured calls, so discrete outputs are the common case here rather
than the edge case. A run of 30 zeros and 70 ones gives `PsiTarget(B4, 0)` = 0.30 inclusive and
**0.00** strict. Not a rounding difference; the whole answer.

No inclusive form exists upstream, so the predicate is computed at the binding. That is a
different predicate rather than a second implementation — there is nothing to delegate to. If
BusinessMath grows a `probabilityAtOrBelow`, that is the one call site to change.

**Two wrong answers in a row on the same row, and neither would have failed a test.** The first
came from trusting the matrix; the second from reading a function's name instead of its body.

### `PsiCVaR` and `PsiBVaR`: two functions share a name, and only one is right

Frontline, verbatim: PsiCVaR is *"computed as the negative of the mean value of the specified
uncertain function for the trials that lie between PsiMin(cell) and PsiPercentile(cell,
1-percentile), **inclusive**"*, and *"Like PsiBVaR, PsiCVaR returns a loss as a positive number."*

**BusinessMath has two `conditionalValueAtRisk` functions, in different types, computing different
things.** The matrix named the wrong one.

| | tail | shape |
|---|---|---|
| `FinancialSimulation.conditionalValueAtRisk` | **count** — worst `ceil(n(1−c))` sorted | takes a `(FinancialProjection) -> Double` metric |
| `SimulationResults.conditionalValueAtRisk` | **value** — `filter { $0 <= varThreshold }` | reads raw trial values |

The second is Frontline's definition exactly: everything at or below `PsiPercentile(cell, 1−p)`,
inclusive, no count anywhere. It is also the right *shape* — Psi statistics read a cell's ten
thousand trial values, not a projection model behind a metric closure.

So the mathematics stays upstream and **only the sign flips at the binding**, as for `PsiBVaR`.
`SimulationResults.valueAtRisk` likewise returns the raw percentile rather than a positive loss.

I had reported a tie residue here — that Frontline defines the tail by value and BusinessMath by
count, so they would disagree when trials tie at the boundary. **That was true of the function the
matrix named and false of the function anyone would actually use.** MinLP checked rather than
taking it, which is the discipline this section keeps being about.

The regression test that distinguishes the two definitions, rather than merely exercising the
function: one trial at −10 and ninety-nine at 0. The value-based tail is all one hundred trials,
mean −0.1, reported 0.1. A count-based tail averages the worst five to −2 and reports 2. Twenty
times apart, and both are numbers a reader would accept.

**The lesson, third time on this page:** a name is not evidence. Neither is a description — mine
included. `probabilityBelow` *looked* right and counts strictly; `conditionalValueAtRisk` was
*reported* wrong by me and is exact. Only the body settles it, and when two bodies share a name,
which one you are looking at settles it first.

### The `provider` column names a *type*, and types are not unique

`PsiCVaR` was not one bad row. **Every statistic the matrix names exists in more than one place**,
and the column named the wrong family throughout:

```
valueAtRisk             FinancialSimulation:277   RiskMetrics:91
conditionalValueAtRisk  FinancialSimulation:308   RiskMetrics:162
percentile              FinancialSimulation:194   Percentiles:178   (+3 more)
probabilityBelow        FinancialSimulation:378   SimulationResults:194
probabilityAbove        FinancialSimulation:411   SimulationResults:172   (+1 more)
mean                    FinancialSimulation:161   statistics over trial values
```

`percentile` resolves five ways; `probabilityAbove` three.

The `FinancialSimulation` family takes a `metric:` closure over `[FinancialProjection]` — a
projection model. The other reads raw trial values. **For a Psi statistic the second is always the
right shape**, because `PsiMean(B4)` reads a cell's ten thousand trial values, not a model behind a
closure. Seven rows repointed as a class: `PsiMean`, `PsiMeanCI`, `PsiMeanCIB`, `PsiPercentile`,
`PsiPercentileCI`, `PsiPercentileD`, `PsiPercentiles`.

For `mean` and `percentile` the mis-pointer happens not to change the answer. That is a property of
those two functions, not of the column — anyone binding from it faced the same coin-flip that
produced the `PsiCVaR` error, and got lucky rather than right.

**So the column is weaker evidence than it looks.** A bare type name does not identify a function
when the name is shared, and nothing in a TSV can. Where the choice matters the row now says which
family and why; where a row still names a bare symbol, resolve it before binding.

### `PsiTarget`, checked again in the second family

`SimulationResults.probabilityBelow` exists too — and also counts strictly:

```swift
let countBelow = values.filter { $0 < threshold }.count
```

So there is no inclusive form in *either* family, and computing the predicate at the binding is
necessary rather than a workaround. That conclusion survives the correction that overturned the
one next to it.

### `PsiXtoP` is the same function under another name

Frontline documents `PsiTarget(cell, target, simulation)` and `PsiXtoP(cell, target, simulation)`
as interchangeable, with identical arguments. The matrix had `PsiXtoP` as `unreviewed` with no
provider, so nothing recorded that binding one binds the other — or that getting the inclusivity
wrong gets it wrong twice.

### `PsiBVaR` was missing from the file altogether

Not excluded — *absent*. It is also absent from BusinessMath's `psi_functions.tsv`, which is where
ours came from, and that file's README already names the cause: several of Frontline's pages render
as images, so a text-only scrape misses them silently.

It is documented, and derivable from a function already being bound:

> `PsiBVaR(A1, 0.95)` equals `–PsiPercentile(A1, 0.05)`

`(cell, percentile, simulation)`, losses positive at the right tail. The "B" is for Basel, to
distinguish it from `PsiVar()` in the Premium Solver Platform. Measured in 3 of 6 workbooks.

**The lesson is about provenance.** Both this and the `PsiTarget` error came from a scrape treated
as complete. A row that is absent looks identical to a row nobody needs, and the only thing that
distinguishes them is running against real files.

## Also still open upstream## Also still open upstream## Also still open upstream

**The NASD February rule.** `thirty360` gives 302/360 for 2020-02-29 → 2020-12-31 where Excel
gives 301/360. This one *is* a blocker: basis 0 is the basis every one of the corpus's 3,425
`YEARFRAC` calls uses, and it is the whole of the outstanding disagreement list — 260 `IF`, 202
`YEARFRAC`, 142 `YEAR`, 140 `AND`, all the same defect and its wrappers.

Pinned by `testTheFebruaryEndOfMonthRule` with `XCTExpectFailure`, so it reports an unexpected
pass when it lands. The daylight-saving defect in `actual/360`, `actual/365` and `actual/actual`
*was* fixed in 2.14.0 and its three guards have been removed.
