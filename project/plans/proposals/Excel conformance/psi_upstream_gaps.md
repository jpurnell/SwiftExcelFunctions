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

## Also still open upstream## Also still open upstream## Also still open upstream

**The NASD February rule.** `thirty360` gives 302/360 for 2020-02-29 → 2020-12-31 where Excel
gives 301/360. This one *is* a blocker: basis 0 is the basis every one of the corpus's 3,425
`YEARFRAC` calls uses, and it is the whole of the outstanding disagreement list — 260 `IF`, 202
`YEARFRAC`, 142 `YEAR`, 140 `AND`, all the same defect and its wrappers.

Pinned by `testTheFebruaryEndOfMonthRule` with `XCTExpectFailure`, so it reports an unexpected
pass when it lands. The daylight-saving defect in `actual/360`, `actual/365` and `actual/actual`
*was* fixed in 2.14.0 and its three guards have been removed.
