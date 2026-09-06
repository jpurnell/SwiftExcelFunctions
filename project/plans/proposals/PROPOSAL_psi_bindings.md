# Proposal — Binding the Psi simulation family

**Status:** Draft, written ahead of the distributions landing
**Spans:** SwiftExcelFunctions (the bindings), BusinessMath (the distributions)

Written now so the binding work is mechanical when BusinessMath's distributions arrive, and so
the two decisions that are *not* mechanical get made before twenty-seven functions are written
against the wrong shape.

---

## 1. Objective

**Objective:** Read a workbook that used Risk Solver without needing Risk Solver.

Frontline's add-in is closed source, and a workbook that used it carries `Psi*` calls whether or
not the add-in is present. Today they are `#NAME?`. That is the dependency this project exists to
break.

---

## 2. What the corpus actually contains

Measured across 2,236 workbooks: **27 distinct functions, 1,950 calls, 41 workbooks.**

| function | calls | books | arities seen |
|---|---:|---:|---|
| `PsiBernoulli` | 449 | 9 | 1, 2 |
| `PsiSenParam` | 280 | 19 | 2, 3 |
| `PsiNormal` | 252 | 13 | 2, 3 |
| `PsiOutput` | 167 | 41 | 0 |
| `PsiLogNormal` | 153 | 5 | 2 |
| `PsiTriangular` | 130 | 13 | 3, 4, 5 |
| `PsiBaseCase` | 129 | 6 | 1 |
| `PsiMean` | 108 | 23 | 1, 2 |
| `PsiOptParam` | 46 | 26 | 2, 3 |
| `PsiDiscrete` | 46 | 8 | 2, 3, 4, 8 |
| `PsiUniform` | 33 | 10 | 2, 3, 4 |
| `PsiPercentile` | 28 | 3 | 2, 3 |
| `PsiName` | 25 | 2 | 1 |
| `PsiStdDev` | 21 | 4 | 1 |
| `PsiBinomial` | 20 | 1 | 2 |

with a tail of `PsiCVaR`, `PsiTarget`, `PsiOptValue`, `PsiBVaR`, `PsiSimParam`, `PsiIntUniform`,
`PsiMin`, `PsiCorrIndep`, `PsiCorrDepen`, `PsiPoisson`, `PsiMeanCI`, `PsiSenValue`.

`PsiOutput` is the most *widespread* — 41 workbooks, more than any other — and is already
implemented, because it is a marker rather than mathematics.

---

## 3. The shape, and the decision it forces

The variable arities are not variants. They are a fixed parameter list followed by optional
**property functions**:

```
PsiTriangular(min, likely, max)                          3 args
PsiTriangular(min, likely, max, PsiBaseCase(v))          4
PsiTriangular(min, likely, max, PsiBaseCase(v), PsiName("…"))   5

PsiBernoulli(p)                                          1
PsiBernoulli(p, PsiBaseCase(v))                          2

PsiUniform(min, max, PsiBaseCase(v))                     3
PsiDiscrete(values, probs, PsiBaseCase(2))               3
PsiDiscrete(values, probs, PsiName("Aggressive Launch")) 4
```

### A property function cannot be recognised by its value

This is the decision that has to be made first, because it determines the *type* of every
binding. The evaluator evaluates arguments before calling a function, so a distribution handed
`PsiBaseCase(5)` and one handed a literal `5` receive the same thing: `.number(5)`. Nothing in
the value says which it was.

So **every Psi distribution must be a context function**, reading `EvaluationContext.arguments`
to see which trailing arguments are `.function("_xll.PsiBaseCase", …)` rather than parameters.
`ExcelFunction` already has that form, and the context already carries `arguments: [FormulaAST]`
and `random: (any RandomSource)?` — the two things needed. No new plumbing.

Written as ordinary value functions instead, `PsiTriangular(a, b, c, PsiBaseCase(v))` would read
the base case as a fourth *parameter* and be wrong in a way that produces plausible numbers.

### The property functions still have to evaluate

They are arguments, so the evaluator evaluates them regardless. Unregistered they are `#NAME?`,
and error propagation carries that outward — so an unimplemented `PsiBaseCase` would make its
whole enclosing distribution fail even after the distribution is written.

`PsiBaseCase` and `PsiName` are therefore implemented **now**, ahead of the distributions. They
are structural, not stochastic: `PsiBaseCase(v)` is `v`, `PsiName(text)` is `text`.

---

## 4. What a distribution answers when nothing is simulating

The corpus settles this, and it is not what one might assume.

Of 90 cells carrying an explicit `PsiBaseCase(X)`, **71 cache the value at X and 19 cache a
draw** — the difference being whether the workbook was saved with a live simulation, and nothing
in the file saying which. So Risk Solver shows the base case when idle and a sample when running.

Proposed, matching that and matching how `RAND` already behaves here:

| situation | answer |
|---|---|
| a random source is supplied | a sample from the distribution |
| no source, `PsiBaseCase` given | the base case |
| no source, no base case | `#VALUE!` |

The last row is the same rule `RAND()` follows: this package supplies no randomness of its own
and will not invent any. Refusing is honest; returning a mean unasked would be a number nobody
requested and nothing could distinguish from a real one.

---

## 5. Verification, and why the cached values are not oracles

**Psi values cannot be checked against the corpus.** They are Monte Carlo with no published seed,
so a cached value is one draw from one run. The oracle excludes the whole family for exactly this
reason, and counting them as disagreements would hold the agreement number down by something no
work could fix.

So verification is against the **published specification**, in three layers:

1. **Signature tests** from the measurement above — arity, and that a property function is
   recognised as one rather than read as a parameter. Reproducible and independent of any draw.
2. **Distributional tests** with a seeded source: over enough samples the mean, variance and
   support converge to the analytic values. `SeededRandomSource` makes these exactly repeatable.
3. **Base-case tests**, which are fully deterministic and need no source at all.

The traps already recorded in the master plan apply and are the reason layer 1 matters:
`PsiLogNormal` takes the *arithmetic* mean and deviation while `PsiLogNorm2` takes the log-scale
ones; `PsiTriangular` is published `(a, c, b)`, which positionally is `(min, likely, max)` and
must not be "corrected"; `PsiNormalSkew(a, b, c)` is `(lower ≈ −3sd, upper ≈ +3sd, skew)`, not
`(mean, sd, skew)`.

---

## 6. What is needed from BusinessMath

Sampling from: Bernoulli, Normal, LogNormal, Triangular, Uniform, IntUniform, Discrete,
Binomial, Poisson — which covers 1,166 of the 1,950 corpus calls.

The rest are not distributions and mostly do not need BusinessMath at all:

- **Statistics of a completed run** — `PsiMean`, `PsiStdDev`, `PsiPercentile`, `PsiCVaR`,
  `PsiBVaR`, `PsiMeanCI`, `PsiMin`. These read the *results* of a simulation, which needs a
  simulation engine rather than a distribution. Out of scope for the first pass.
- **Declarations** — `PsiSenParam`, `PsiOptParam`, `PsiSimParam`, `PsiTarget`, `PsiCorrIndep`,
  `PsiCorrDepen`. Markers describing how a run should be set up.
- **Markers** — `PsiOutput`, `PsiName`, `PsiBaseCase`. Done or doing.

The first pass is therefore the nine distributions plus the markers, which is most of the calls
and all of the mathematics.

---

## 7. Open questions

1. **Does a seeded stream need to match anything?** Nothing external can be matched, so the only
   requirement is that the same seed gives the same workbook twice. Confirmed available.
2. **Do the run-statistics functions belong here at all?** `PsiMean` is 23 workbooks — wide, and
   answerable only with a simulation engine. Worth deciding whether that engine is in scope
   before the tail of this list looks like a gap.
3. **Where do the declarations evaluate to?** `PsiSenParam(0%, 10%, 0%)` sits inside a live
   formula; a marker returning 0 would change the arithmetic. Probably it should return its first
   argument — the base value — but that needs one corpus check before it is assumed.
