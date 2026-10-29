# Design Proposal — Correlated draws

**Status:** Proposed, awaiting approval
**Date:** 2026-10-05
**Scope:** `PsiCorrMatrix`, `PsiCorrDepen`, `PsiCorrIndep` — correlated sampling via a Gaussian
copula over the input vector the survey already indexes.

---

## 1. Objective

**Objective:** Draw a group of uncertain cells jointly, with a correlation structure the
workbook states, rather than independently.

**Master Plan Reference:** the `PSI` coverage matrix — 193 have, 71 out of scope, 17 not ours,
**13 bindable**, 1 new. `PsiCorrMatrix` is one of the 13; the other three correlation rows are
recorded as out of scope with an architectural reason this proposal revisits.

```
PsiCorrMatrix   bindable      isValidCorrelationMatrix                          confirmed
PsiCorrDepen    out of scope  joins inputs into a correlated group; correlation
                              is a property of a set of inputs drawn together,
                              and this evaluator draws one cell at a time       confirmed
PsiCorrIndep    out of scope  the same, declaring independence within a group    confirmed
PsiCopula       out of scope  a dependence structure across several inputs —
                              needs the joint draw this evaluator does not make  confirmed
```

The reason given is true of `InterpretedRun` as written. This proposal argues it is a statement
about the *sampler*, not about the evaluator, and that the seam needed to fix it was built
before the objection was recorded.

---

## 2. Motivation

**Current situation.** A model whose author wrote
`PsiNormal(50, 10, PsiCorrMatrix(Corr!$A$1:$C$3, 1))` runs here with **independent** draws. The
recognizer records `PsiCorrMatrix` in `DistributionCall.unhandledProperties`, the app shows
`Not modelled: PsiCorrMatrix` in orange beside the input, and the run proceeds.

**Why that is worse than it sounds.** Independence is not a neutral default. Dropping a positive
correlation makes the aggregate **narrower** — variances add instead of compounding through the
covariance term — so the answer comes back more confident than the model says. This package
exists to catch exactly that failure shape, and here it is producing it. The orange warning is
the only thing standing between a reader and a plausible wrong interval.

**Workaround today, and its limits.** Time-correlation can be written in the sheet without any
of this, and should be: a price path is better expressed as a recursion over independent shocks
than as an *n×n* matrix over quarters.

```
P₁ = P₀ · EXP(μΔ + σ√Δ · Z₁)                 Z_t = PsiNormal(0,1), independent
Z_gas = ρ · Z_oil + SQRT(1-ρ²) · W           W   = PsiNormal(0,1)
```

That covers paths and the two-variable case completely. What it does not cover is a correlation
structure somebody **measured** across several variables and wants to state directly — and it
cannot be retrofitted onto a workbook written by somebody else, which is the reading case.

**Measured — and it qualifies "Why that is worse than it sounds" above.** That paragraph
argued this is a live fidelity problem for *reading* existing workbooks. It was written before
it was checked, and the check does not support it:

```
PsiCorrMatrix   calls=0   books=0        PsiCopula    calls=0   books=0
PsiCorrDepen    calls=0   books=0        PsiMVNormal  calls=0   books=0
PsiCorrIndep    calls=0   books=0
                                         (PsiTriangular 60/17, PsiOutput 24/11, for scale)
```

**No workbook in the corpus declares correlation at all** — 0 calls, 0 books, all four
functions, over a census that read 2,236 of 2,283 workbooks (43 iCloud timeouts, 4 unreadable).
Only 19 `PSI` functions appear anywhere in it.

So the narrowing-the-interval failure described above is real in kind and **hypothetical in this
corpus**. The honest motivation is narrower: this is an *authoring* gap, it is one of the 13
`bindable` rows, and a multi-commodity model with a measured correlation structure is the case
that wants it.

That is the same epistemic position as the function-argument intersection gap, which was left
open at round sixteen on the reasoning that *"a 300-workbook run at 4,524,171 comparable cells
does not contain one case that turns on it"* — true of the corpus, false of the world, and the
first real workbook opened by the consuming app turned on it twelve times. **"No corpus call"
is a statement about the corpus.** It is a reason to rank this below work the corpus does
exercise; it is not a reason to call it unnecessary.

---

## 2a. What already exists, checked 2026-10-27

This proposal is **not** superseded, but its scope is narrower than §3 implies and the
difference matters.

`BusinessMathPro/Simulation/Kernel/SimulationKernel.swift` is "the single engine that generates
all correlated risk factor paths for a scenario." It builds the correlation matrix and its
**Cholesky factor**, refuses a non-PSD matrix (`SimulationError.correlationNotPSD`), carries the
probability measure as a type parameter, and its own usage example is WTI against Henry Hub.
`Risk/Correlation/` adds `PSDRepair` and `LedoitWolfShrinkage`. BusinessMath beneath it has
`CorrelatedNormals` and `isValidCorrelationMatrix`.

**None of that can drive this evaluator**, and the reason is the point. The kernel correlates
*risk factors it owns*, declared in a registry and stepped by functions it was given. A
spreadsheet's draws are `PsiNormal(…)` calls discovered in cells, evaluated in a topological
order the workbook dictates, pulling uniforms one at a time from a stream. The kernel cannot
enumerate them and the evaluator cannot be handed a pre-built path set.

So what survives from §3 is the **integration** — `inputIndex`, `IndexedUniforms`, the
one-uniform-per-draw invariant and the `consumesUnindexedUniforms` guard. What should be struck
is any suggestion that the copula is new work: the Cholesky, the PSD validation and the repair
are all written, tested and in a package this family already depends on. §9 already said to bind
`isValidCorrelationMatrix`; it should bind the rest too, and §12's "strongest case for a
different approach" should have included "read BusinessMathPro first", which it did not.

---

## 3. Proposed Architecture

The key claim: **no change to `FormulaEvaluator`, and none to either run engine's evaluation
loop.** The work is confined to how the uniform stream is produced.

### Why that is possible — three facts, each verified

**(a) Every Psi distribution is an inverse-CDF draw consuming exactly one uniform.**
73 of them (`BuiltinRiskSolverDistributions` 9, `MoreDistributions` 45,
`RemainingDistributions` 19) are built through one helper:

```swift
// BuiltinRiskSolverDistributions.sampling(_:minArgs:maxArgs:quantile:)
return .number(try drawing(random.nextUniform()))      // one call, unconditionally
```

`psiNormal` returns `{ distribution.quantile($0) }` — a quantile, not Box–Muller. One uniform in,
one value out.

**(b) The property modifiers do not redraw.** Truncation was the obvious risk and it is
rescaling in probability space, not rejection:

```swift
// restricted(_:between:and:)
return { probability in try inverse(start + probability * span) }
```

So `PsiTruncate`, `PsiTruncateP` and `PsiShift` compose the quantile. The uniform count is
unchanged by any of them.

**(c) The index already exists.** `UncertainCell.inputIndex` is documented as *"this draw's
position in the `[Double]` a sampler fills, one per trial."* The surveyor assigns it in reading
order, and that order is already load-bearing — it is what makes a seeded run reproducible
across processes. `Lowerer` consumes it (`builder[index]`); `InterpretedRun` ignores it and pulls
from a stream instead.

Together: consumption order *is* `inputIndex` order. A `RandomSource` that serves a pre-computed
vector in that order produces correlated draws that the evaluator cannot tell from independent
ones.

### New Files

- `Sources/SwiftExcelFunctions/CorrelationGroup.swift` — the group model and the copula.
- `Sources/SwiftExcelFunctions/IndexedUniforms.swift` — a `RandomSource` serving a fixed vector.
- `Tests/SwiftExcelFunctionsTests/CorrelatedDrawTests.swift`
- `Tests/SwiftExcelFunctionsTests/IndexedUniformsTests.swift`

### Modified Files

- `PsiRecognizer.swift` — recognise the three properties; carry them on `DistributionCall`.
- `ModelSurvey.swift` — assemble `[CorrelationGroup]`; add `consumesUnindexedUniforms`.
- `BuiltinRiskSolverDistributions.swift` — `attached(_:_:)` stops appending the correlation
  properties to `parameters` (today an unrecognised property falls through to
  `default: result.parameters.append(value)`).
- `BuiltinRiskSolverProperties.swift` — register the three names so they are not `#NAME?`.
- `InterpretedRun.swift` / `ParallelRun.swift` — build the per-trial vector; pass
  `IndexedUniforms` instead of the raw stream when a group exists.

**Module placement:** all inside `SwiftExcelFunctions`. No new module; no new dependency.

---

## 4. API Surface

```swift
/// A set of inputs drawn together, with the correlation the workbook states.
public struct CorrelationGroup: Sendable, Equatable {

    /// The name the workbook gives the group — `PsiCorrMatrix`'s matrix range, rendered.
    public let name: String

    /// The draws in the group, by their position in the trial's input vector.
    ///
    /// Ordered by the matrix position each call declared, **not** by reading order: the
    /// author decides which row of their matrix a cell occupies, and a group that silently
    /// renumbered them would correlate the right cells by the wrong coefficients.
    public let inputIndices: [Int]

    /// Row-major, square, symmetric, unit diagonal, positive semi-definite.
    public let matrix: [[Double]]

    public init(name: String, inputIndices: [Int], matrix: [[Double]]) throws
}

/// What a correlation structure can be wrong about.
public enum CorrelationError: Error, Equatable, Sendable {
    /// The matrix is not square, not symmetric, has a diagonal off 1, or is not PSD.
    case matrixIsNotACorrelationMatrix(name: String)
    /// `n` cells claim membership of an `m × m` matrix.
    case groupSizeDisagreesWithMatrix(name: String, cells: Int, order: Int)
    /// Two cells claim the same row.
    case duplicatePosition(name: String, position: Int)
    /// A position outside `1...order`.
    case positionOutOfRange(name: String, position: Int, order: Int)
}

/// A `RandomSource` serving a fixed vector, then falling back to a stream.
///
/// The fallback is not a convenience: a trial may consume more uniforms than it has indexed
/// draws — `RANDARRAY` alone pulls `rows × columns` — and running out mid-trial must not
/// silently repeat a value.
public struct IndexedUniforms: RandomSource {
    public init(_ values: [Double], then overflow: any RandomSource)
    public func nextUniform() -> Double
    public func nextInteger(below bound: Int) -> Int
}

extension ModelSurvey {
    /// The correlated groups this model declares, empty when it declares none.
    public var correlationGroups: [CorrelationGroup] { get }

    /// Whether the model pulls uniforms outside the indexed draws — `RAND`, `RANDBETWEEN`,
    /// `RANDARRAY`, or a multivariate `Psi` draw.
    ///
    /// **The guard on the whole design.** Position-to-uniform mapping holds only while every
    /// consumer takes exactly one in a known order. One `RANDARRAY` breaks that for every draw
    /// after it, and a run that correlated the wrong cells would report a model nobody wrote.
    public var consumesUnindexedUniforms: Bool { get }
}

extension DistributionCall {
    /// The group this call joins, and the row it occupies, where it declares one.
    public var correlation: (group: String, position: Int)? { get }
    /// Whether this call declared itself independent of its group — `PsiCorrIndep`.
    public var isDeclaredIndependent: Bool { get }
}
```

**Consumer-facing change:** none required. `InterpretedRun` and `ParallelRun` keep their
signatures; a model with no correlation group behaves identically, bit for bit, because the
uniform sequence is unchanged.

---

## 5. MCP Schema

**Tool Description:** Describe the correlation structure a workbook declares, and whether the
run can honour it.

```json
{
  "groups": [
    {
      "name": "Corr!$A$1:$C$3",
      "cells": ["Assumptions!B4", "Assumptions!B5", "Assumptions!B6"],
      "matrix": [[1.0, 0.8, 0.3], [0.8, 1.0, 0.25], [0.3, 0.25, 1.0]],
      "honoured": true
    }
  ],
  "consumesUnindexedUniforms": false,
  "reason": null
}
```

**Parameter Types:**
- `groups` (array): one entry per declared correlation group.
  - `name` (string): the matrix range as the workbook writes it.
  - `cells` (array of string): sheet-qualified addresses, in matrix-row order.
  - `matrix` (array of array of number): square, symmetric, unit diagonal.
  - `honoured` (boolean): false when the run fell back to independent draws.
- `consumesUnindexedUniforms` (boolean): true when `RAND`-family or multivariate draws are
  present, which forces the fallback.
- `reason` (string | null): why a group was not honoured, for display beside the results.

---

## 6. Constraints & Compliance

**Concurrency:** `CorrelationGroup` and `IndexedUniforms` are `Sendable` value types.
`ParallelRun`'s lanes are `@Sendable` closures that cannot reach `self`, so the groups are
resolved once before the lanes start and passed in — the same shape as `homeSheet`.

**Determinism:** the per-trial vector is derived from the same seed by the same stream order, so
a correlated run is as reproducible as an independent one. `ParallelRun` derives each trial's
generator from `streamSeed(seed, trial)`, which is unchanged.

**Safety:** no force unwraps. Cholesky is BusinessMath's, already in use by `PsiMVNormal`.
Matrix validation happens once per survey, not per trial.

**Division safety:** Φ⁻¹ and Φ are quantile/CDF calls on the normal distribution; no division by
a computed denominator is introduced.

**No suppression:** the fallback path reports, it does not silence. A group that cannot be
honoured is named, with its reason, in the survey.

---

## 7. Source & API Compatibility

**Breaking changes:** none. Three new public types, two new computed properties on existing
public types, no signature changes.

**Incremental adoption:** total. A workbook with no correlation property produces an empty
`correlationGroups`, and the engines take the existing path.

**Type-checking risk:** none — no overloads of existing functions, no new initialisers on
existing types.

**Behavioural change for existing callers:** a workbook that *does* declare correlation changes
its answer, which is the point. That is a fidelity fix, and the `unhandledProperties` warning it
removes is the record that the old answer was known to be wrong.

---

## 8. Backend Abstraction

Not applicable at the expected scale, and worth stating why rather than leaving it open.

The Cholesky factorisation is **once per survey**, not per trial: an *n×n* decomposition where
*n* is the number of correlated cells, typically under 20. The per-trial cost is one
matrix–vector product (*n²* multiply-adds) plus *n* calls each to Φ⁻¹ and Φ. At *n* = 20 and
200,000 trials that is 80M multiply-adds — real, but an order below the formula evaluation it
sits beside, and `ParallelRun` already distributes trials across lanes.

If it ever matters, the factor is cached and the per-trial product is the only candidate; it
vectorises cleanly through Accelerate. Not proposed now: optimising before measuring is how the
`concurrency` parameter came to silently do nothing.

---

## 9. Dependencies

**Internal:**
- `PsiRecognizer` — property recognition.
- `ModelSurvey` / `UncertainCell.inputIndex` — the index this design rests on.
- `RandomSource` — the protocol `IndexedUniforms` conforms to.

**External:** none new. BusinessMath is already a dependency and already resolved:
- `isValidCorrelationMatrix(_:) -> Bool` — the binding the coverage matrix names.
- `CorrelatedNormals(means:correlationMatrix:) throws` and `sample(using:)` — Cholesky,
  already exercised by `PsiMVNormal` / `PsiMVLogNormal`.

That both halves already exist, under the names the matrix recorded, is the strongest evidence
that `bindable` was the right classification and that only the plumbing was missing.

---

## 10. Test Strategy

**Test categories**

- **Golden path** — two normal marginals at ρ = 0.8; recovered Pearson ≈ 0.8.
- **Marginals preserved** — a copula must not change what each cell is distributed as. Each
  marginal's mean and standard deviation match an independent run of the same seed count.
- **Non-normal marginals** — two triangulars at ρ = 0.8; Pearson is *not* 0.8, Spearman is.
- **Determinism** — same seed, same values, including across lane counts in `ParallelRun`.
- **Engines agree** — `InterpretedRun` and `ParallelRun` produce identical vectors.
- **Validation** — non-symmetric, non-PSD, wrong-size, duplicate-position, out-of-range.
- **The guard** — a model containing `RANDARRAY` reports `consumesUnindexedUniforms` and falls
  back, with the group named rather than silently dropped.
- **No regression** — a model with no correlation produces a bit-identical uniform sequence.

**Reference truth**

For a Gaussian copula the rank correlations are closed-form and independently verifiable:

| Measure | Formula | At ρ = 0.8 |
|---|---|---|
| Spearman ρ_S | (6/π)·arcsin(ρ/2) | **0.785939** |
| Kendall τ | (2/π)·arcsin(ρ) | **0.590334** |

(Standard results; reproducible in one line of scipy, and computed here rather than recalled.)

**Validation trace (required)**

1. Two `PsiNormal(0,1)` in a group with ρ = 0.8, 200,000 trials, seed 42.
   → sample **Pearson ≈ 0.800 ± 0.005**. For normal marginals the copula preserves Pearson
   exactly, so this is the sharpest available assertion.
2. The same group, same seed, read as ranks → **Spearman ≈ 0.7859 ± 0.005**, matching the
   closed form above. This is the assertion that distinguishes a real copula from a
   linear-combination fudge, which would pass (1) and fail (2) on non-normal marginals.
3. Two `PsiTriangular(0,1,2)` at ρ = 0.8 → **Spearman ≈ 0.7859**, Pearson *not* 0.8.
   This is the test that fails if the implementation correlates the values instead of the
   uniforms.
4. Each marginal of (3) against an uncorrelated run: mean and σ equal within Monte Carlo error.

Tolerances are stated as ± because these are sampling estimates; the standard error of a
correlation at n = 200,000 is roughly (1-ρ²)/√n ≈ 0.0008, so ±0.005 is six standard errors and
will not flake.

---

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `project/decisions/architecture_decisions.md` — ADR-001 (Excel is the
      specification), ADR-002 (byte functions), ADR-003 (zero-snap).
- [x] Supersede an existing ADR? **No.**
- [x] Amend an existing ADR? **No.**
- [x] New ADR required? **Yes — ADR-004.**

**New ADR draft:**
- **Title:** Correlation is sampled, not evaluated — a Gaussian copula over the indexed input
  vector
- **Category:** architecture
- **Key decision:** Correlated draws are produced by filling the trial's input vector before
  evaluation begins, so the evaluator continues to draw one cell at a time and the correlation
  lives entirely in the sampler; this holds only while every draw consumes exactly one uniform
  in index order, which is therefore made an explicit, tested invariant rather than an
  incidental property of the current distributions.

The ADR is required because it pins an invariant that future distribution work must not break.
Adding a rejection-sampled distribution would silently invalidate every correlated run; the ADR
is what makes that a reviewable change rather than a discovery.

---

## 12. Adversarial Review

**Strongest case for a different approach**

Pass `inputIndex` into `FormulaEvaluator` and have each `Psi` call read *its own* slot, instead
of relying on consumption order. A reviewer would push for this, and they would have a point:
it removes the invariant that section 11 has to defend with an ADR. Correlation would survive a
rejection-sampled distribution, a `RANDARRAY`, and any future reordering.

Why it might be better: it is robust rather than merely correct-today. The design proposed here
is correct *because of* a property of the current 73 distributions, and that property is not
written down anywhere until this proposal writes it down.

Why we are not doing it: the evaluator would need the survey threaded through every call —
`EvaluationContext` would carry an index map, and every `sampling(…)` closure would need to know
which call it is, which the AST does not currently tell it. That is a change to the evaluator's
contract to serve a sampling concern, and it would land in the middle of the hottest loop in the
package. The guard in section 4 (`consumesUnindexedUniforms`) buys most of the robustness for a
fraction of the blast radius. **If the guard proves to fire often in the corpus, this
conclusion should be revisited** — that is a measurement, and it is in Open Questions.

**Where this design is most likely wrong**

The load-bearing assumption is *one uniform per draw, consumed in index order*. It is true of all
73 distributions today and verified above. It is not guaranteed by anything. Specifically:

- A future distribution with no closed-form inverse would likely be rejection-sampled, and would
  break every correlated run in the package without failing a single existing test. The ADR and
  a dedicated invariant test are the mitigation; neither is a compiler.
- `PsiMVNormal` already violates it. It is excluded by the guard, which means a workbook mixing
  `PsiMVNormal` and `PsiCorrMatrix` gets no correlation at all — defensible, and worse than it
  sounds if such workbooks turn out to be common.

The constraint accepted without much challenge: that a Gaussian copula is the right dependence
structure. It is what the matrix's own reasoning assumes and almost certainly what Frontline
does, but *almost certainly* is doing real work in that sentence. See Open Questions.

**What an experienced critic would say**

> "You have built correctness on an undocumented coincidence about how 73 functions happen to
> consume randomness, and the test that would catch its violation is one you also have to
> remember to write."

Proceeding anyway, with two changes made in response: the invariant is promoted to an ADR rather
than a comment, and `consumesUnindexedUniforms` turns the dangerous cases into a reported
fallback instead of a wrong answer.

**A third objection the review missed**, found by the measurement in §2 rather than by this
section: the motivation was overstated. The proposal argued from corpus fidelity before checking
the corpus, and the corpus contains no correlated models at all. The design is unaffected; the
*priority* is lower than §2 originally implied, and that is exactly the kind of error this
section exists to catch and did not. The cases that remain silent are ones where somebody adds a
rejection-sampled distribution — and that is exactly what ADR-004 exists to make visible.

---

## 13. Alternatives Considered

**Alternative 1 — Thread `inputIndex` through `FormulaEvaluator`.**
- Advantage: no ordering invariant; robust to future distributions and to `RAND`.
- Disadvantage: changes the evaluator's contract for a sampling concern; touches the hottest
  loop; every `sampling(…)` closure needs identity it does not currently have.
- Why not now: see Adversarial Review. Revisit if the guard fires often.

**Alternative 2 — Iman–Conover rank reordering.**
- Advantage: distribution-free; induces a target *rank* correlation exactly, by permuting an
  already-drawn sample. No assumption about the dependence structure at all.
- Disadvantage: it is a post-process over the whole sample, so it needs every trial's draws in
  memory before any output can be computed, and it destroys the trial-by-trial streaming that
  `ParallelRun`'s progress reporting and cancellation depend on. It also cannot be made
  lane-independent: the permutation is global.
- Why rejected: incompatible with the engine's streaming shape, which is a deliberate design
  this package already paid for.

**Alternative 3 — Express correlation in the sheet and implement nothing.**
- Advantage: zero code; works today; strictly better for time-series paths, where a recursion
  beats an *n×n* matrix.
- Disadvantage: cannot be retrofitted onto somebody else's workbook, which is the reading case
  and the one that matters for fidelity.
- Why rejected: it is a good answer for *authoring* and no answer at all for *reading*. It is
  recommended alongside this proposal, not instead of it.

**Alternative 4 — Implement `PsiCorrMatrix` only; leave `PsiCorrDepen`/`PsiCorrIndep` out of
scope.**
- Advantage: smaller; matches the coverage matrix exactly, which lists only the first as
  bindable.
- Disadvantage: the other two are group membership and group exclusion over machinery this
  proposal builds anyway. Leaving them out means a second pass over the same files.
- Why rejected: marginal cost once the group model exists. `PsiCopula` genuinely stays out of
  scope — a non-Gaussian dependence structure is different work and the matrix's reasoning for
  it still holds.

---

## 14. Future Directions

- **A non-Gaussian copula** (`PsiCopula`) could reuse the group model, substituting the
  dependence function while keeping the index vector.
- **Correlation diagnostics** could report the *realised* correlation of a finished run beside
  the declared one, which would catch a group that was honoured but mis-specified.
- **The app** might offer a correlation group as an authoring affordance — several varied cells,
  a matrix, and a row position each — building on the cross-sheet declarations already shipped.
- **Accelerate-backed** matrix–vector products, if measurement ever shows the per-trial cost
  matters.

---

## 15. Open Questions

1. **What does Frontline's matrix actually mean?** ADR-001 says Excel is the specification, and
   this is a specification question with two defensible readings: the coefficients are Pearson
   correlations *of the underlying normals*, or they are target *rank* correlations of the
   outputs. For normal marginals the two agree; for anything else they differ by the
   (6/π)·arcsin(ρ/2) factor above — about 1.8% at ρ = 0.8, more at the extremes. **This is the
   headline risk of the proposal, and it is semantic, not architectural.** Resolving it needs a
   Risk Solver workbook with a known matrix and non-normal marginals, read against its own
   cached values — the same oracle method used throughout.
2. ~~**How often does the guard fire?**~~ **Answered 2026-10-23: never, on known material.**
   No corpus workbook declares a correlation property, so none can declare one *and* a
   `RAND`-family or multivariate call. `PsiMVNormal` is likewise unused (0/0), making that half
   of the exclusion hypothetical too.

   By the criterion this question set — *"if the answer is 'often', Alternative 1 becomes the
   better design"* — the proposed sampler-only design stands.

   **Two caveats, since this is now load-bearing.** The measurement is of workbooks that do not
   use the feature, which is weak evidence about workbooks that would: a corpus with no
   correlated models says little about how a correlated model is typically written. And the
   first workbook to exercise this will be one written against *this proposal*, where the guard
   is a design constraint rather than a discovery. Revisit if a real Risk Solver model with a
   correlation matrix ever reaches the corpus — which is also what Open Question 1 needs.
3. **Does `PsiCorrDepen` take a coefficient?** The matrix records its arguments as
   `corrname, coefficient`, which suggests a pairwise form rather than membership in a named
   matrix. If so it is a second shape, not a free rider on this one, and may warrant deferral.
4. **Position base.** `PsiCorrMatrix(range, position)` — is `position` 1-based? Assumed yes,
   consistent with Excel's argument conventions, but it is an assumption and a 0-based reading
   would correlate every cell with the wrong row while validating cleanly.
