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

## Bindable upstream, not yet bound here (2)

Three of what were five here have since been bound, after reading Frontline's documentation
rather than reasoning from the type signatures. Recorded because the mistake is worth keeping:

- **`PsiAR1` and `PsiGARCH11`.** I had them down as needing simulation state a cell cannot carry.
  Frontline's signatures pass the previous state *in* — `val0`, `err0`, `stdev0` are arguments,
  supplied by the cell above, precisely because a spreadsheet cell has no memory. One step is
  fully determined, and `StochasticProcess.step(from:dt:normalDraws:)` is exactly that step.
- **`PsiMetalog`.** I read its trailing `prop_fcns` as an argument whose meaning was unstated.
  It is Frontline's general **property-function slot** — the same one carrying `PsiTruncate`,
  `PsiBaseCase` and `PsiName` — and `attached(_:_:)` already strips it. The parameters are the
  three that remain, so the "optional leading bounds" never created an ambiguity.

What remains:

| Function | Provider | What is unresolved |
|---|---|---|
| `PsiMVLogNormal` | `DistributionMVLogNormal` | Documented and unambiguous — µ a vector of means, Σ a covariance matrix, array-entered to spill across cells. Two things are missing on our side, neither of them a question about meaning: `sample(using:)` needs a `RandomNumberGenerator` where we hold a `RandomSource`, and the binding must answer a `CellMatrix` rather than one number. Sampling the marginals independently would type-check and discard the correlation, which is the entire point of the distribution. |
| `PsiMetalogFit` | `DistributionMetalog` | `(num_coef, x_values, y_values)` against `(fittingProbabilities:values:terms:)`. Which of x and y carries the probability is not stated in the signature, and getting it backwards fits a distribution to transposed data — an answer, and the wrong one. |

`PsiMVLogNormal` is the more valuable of the two and is a known piece of work rather than an open
question: an RNG bridge, and an array-returning variant of the sampler.

## Also still open upstream

**The NASD February rule.** `thirty360` gives 302/360 for 2020-02-29 → 2020-12-31 where Excel
gives 301/360. This one *is* a blocker: basis 0 is the basis every one of the corpus's 3,425
`YEARFRAC` calls uses, and it is the whole of the outstanding disagreement list — 260 `IF`, 202
`YEARFRAC`, 142 `YEAR`, 140 `AND`, all the same defect and its wrappers.

Pinned by `testTheFebruaryEndOfMonthRule` with `XCTExpectFailure`, so it reports an unexpected
pass when it lands. The daylight-saving defect in `actual/360`, `actual/365` and `actual/actual`
*was* fixed in 2.14.0 and its three guards have been removed.
