# SwiftExcelFunctions Master Plan

**Purpose:** Source of truth for project vision, architecture, and goals.

Derived from `BusinessMathExcel/project/plans/proposals/PROPOSAL_swift_excel_architecture.md`.
The coverage matrix that scopes the work is `project/plans/excel_function_coverage_matrix.tsv`.

---

## Project Overview

### Mission

Excel's function library, in Swift. One registry a caller can ask for any function by the name
Excel uses, without knowing or caring which package computes it.

### Target Users

- Anyone evaluating spreadsheet formulas in Swift — with or without a spreadsheet file.
- **BusinessMathExcel**, translating workbooks into computational models.
- A workbook-correctness CLI, which is the motivating application: read a model, recompute it,
  and report where it disagrees with itself.

### Key Differentiators

- **No file format.** Hand it a `FormulaAST` and any `CellValueProvider` and it evaluates. No ZIP,
  no workbook, no I/O. That is what makes it independently useful and independently testable.
- **Excel's semantics, not similar ones.** Argument order, coercion, error propagation, and the
  legacy/dotted name pairs are the product. Getting `PsiTriangular(a,c,b)` or `PsiLogNormal`'s
  parameterisation wrong produces plausible numbers, which is worse than an error.
- **The mathematics is delegated, never reimplemented.** BusinessMath owns it. A second `NPV` that
  could disagree with the first is the failure this whole arrangement exists to prevent.

---

## Architecture

### Technology Stack

- **Language:** Swift 6.0+, strict concurrency
- **Build System:** Swift Package Manager
- **Dependencies:** SwiftExcelCore (vocabulary), BusinessMath (mathematics), Foundation

All three are pinned: SwiftExcelCore `0.3.0`, BusinessMath `2.9.0`, and SwiftXLSX `0.15.0` for
tests only.

### The seam

```
FormulaAST  ──►  FormulaEvaluator  ──►  FunctionRegistry  ──►  ExcelFunction
                        │
                        └──►  CellValueProvider   (supplied by the caller)
```

The evaluator never sees a file. `CellValueProvider` is a protocol in Core; SwiftXLSX ships the
`Workbook`-backed conformance, and a test can supply a dictionary.

### Where each function's answer comes from

A caller sees one registry. Underneath there are four sources, and the boundary matters:

| Source | Functions | Why |
|---|---|---|
| This package | `IF`, `IFERROR`, `ISERROR`, coercion, arity | Excel's evaluation semantics. Not arithmetic |
| This package, via `CellValueProvider` | `VLOOKUP`, `INDEX`, `MATCH`, `OFFSET` | they compute an address and read it |
| This package, on shape alone | `TRANSPOSE`, `COUNTBLANK` | the rectangle is the subject, not its values |
| Foundation, swift-numerics | trigonometry, logs, rounding, dates, text, complex | primitives |
| **BusinessMath** | distributions, statistics, financial, Risk Solver | where a second implementation could disagree |
| This package, over a completed run | the `Psi*` statistics — `PsiMean`, `PsiCVaR`, `PsiBVaR` | they read a *run*, not a value; see ``SimulationResultProvider`` |
| This package, simulating | `PsiRecognizer`, `ModelSurveyor`, `InterpretedRun`, `Lowerer` | reading a model, running it, and compiling its propagation |

Excel's sign conventions are applied **here**, at the binding — BusinessMath returns positive
where Excel returns negative, and the flip belongs in the translation, not the mathematics.

---

## Current Status

**Unreleased — the simulation stack.** A Risk Solver workbook now runs.

- [x] `PsiRecognizer` — what a formula declares: draws, outputs, property functions
- [x] `ModelSurveyor` / `ModelSurvey` — the same across a sheet, with input indices assigned
- [x] `SimulationResultProvider` — the seam that lets `PsiMean(B4)` reach a completed run
- [x] `BuiltinRiskSolverStatistics` — seven read-out functions
- [x] `InterpretedRun` — the trial loop: draw, propagate, collect
- [x] `Lowerer` — `FormulaAST` into BusinessMath bytecode, **83% of real outputs**
- [x] 907 tests, gate 45/45 at 0/0

**Seven sheets across six real Risk Solver workbooks run end to end**, 36 outputs,
reproducing exactly under seed. `PROPOSAL_model_graph_simulation.md` is the design;
phases 0 through 4 of its §13 are done.

Six defects came out of running against real files rather than fixtures, and none of
them would have shown up otherwise:

| Found | Was |
|---|---|
| `ModelSurveyor` scanned the bounding rectangle | 34.8s → 1.08s, a 32× cost on sparse-and-wide sheets |
| `$B$8` and `B8` are different `CellRef` keys | a trial's computed value missed, reading Excel's stale cache instead |
| `PsiTarget`'s provider was `probabilityAbove` | the complement of the truth |
| ...and `probabilityBelow` counts strictly `<` | Frontline says "or equal to"; 0.30 vs 0.00 on a Bernoulli output |
| `PsiOutput()` treated as required | rejected a real 126-call model; cost Jeffords 8 of its 14 outputs |
| `Lowerer.audit` re-walked cells per path | 5,400 findings for a handful of cells |

**v0.6.0 — released 2026-09-08.** BusinessMath 2.15.0; the Psi distribution surface.

**v0.5.0 — released 2026-09-05.** Spilling. `FormulaEvaluator.spill`, four integration
tests carrying an array formula out to a file and back, 662 tests. Evaluation produces an
assignment and SwiftXLSX applies one; writing the integration test found three gaps
neither package's own suite could see.

---

**Unreleased — the oracle, and what it found.**

- [x] `ExcelOracleTests` — every formula checked against Excel's own cached value.
      **99.60%** agreement over 155,897 comparable cells
- [x] `MicrosoftSpecificationTests` — the same rules from the published reference,
      runnable in the gate without the corpus
- [x] ADR-001 recorded: Excel is the specification, standards sit beside it
- [x] `NPV` took ranges, `PsiOutput` answers, `_xll.`/`_xlfn.` resolve
- [x] BusinessMath `from: "2.11.0"` — all five `YEARFRAC` bases compute

Three defects nobody had listed, all found by comparing against Excel rather than against
ourselves: every absolute reference resolved to an empty cell, `NPV(rate, B4:B8)` answered
`#VALUE!`, and the actual/* day counts gain an hour across a daylight-saving boundary. The
last is upstream and documented rather than patched.

---

**v0.4.0 — released 2026-09-05.** Whole-column references work.

- [x] `SUM($A:$A)` and friends evaluate instead of answering `#VALUE!`
- [x] The four refusal branches deleted along with the bound that caused them
- [x] 650 tests, gate 45/45 at 0/0

0.3.0's read bound turned the corpus's most common range notation into an error —
87,773 `VLOOKUP` calls' worth. The fix belonged in Core, and this release is mostly
deleting what the bound made necessary here.

---

**v0.3.0 — released 2026-09-05.** Coverage, and shape.

- [x] Corpus function calls the registry can answer: **99.93%** (869,307 of 869,908)
- [x] `VLOOKUP`, `HLOOKUP` and `INDEX` corrected — they were guessing their table's dimensions
- [x] `TRANSPOSE` and `COUNTBLANK`, in a new Array group
- [x] 646 tests, gate 45/45 at 0/0

The correction is the part worth recording. Three positional functions were wrong, and all three
for one reason: the value they read from could not say what shape it was, so each re-derived it
and two derived it wrongly. `VLOOKUP` inferred its table's width by testing divisors;
`INDEX`'s own comment read *"this doesn't work without knowing dimensions."* SwiftExcelCore 0.3.0
gave arrays their dimensions, which is what let all of it be deleted rather than patched. See
`BusinessMathExcel/project/plans/proposals/PROPOSAL_shaped_arrays.md`.

**v0.1.0 — released 2026-09-04.** The 73 functions, the registry and the evaluator arrived by
extraction from SwiftXLSX. 546 tests, gate 45/45 at 0/0.

Against Microsoft's 519 documented worksheet functions:

| Marking | Count | Meaning |
|---|---|---|
| `have` | **160** | registered and answering; verified against the live registry |
| `bindable` | **57** | BusinessMath computes it; needs an Excel-facing binding |
| `new` | 6 | verified absent everywhere |
| `out of scope` | 10 | cube and web — need an OLAP connection or the network |
| `unreviewed` | 286 | no evidence either way; **not** the same as absent |

Risk Solver's 295 PSI functions, reconciled against **BusinessMath 2.14.0**:

| Marking | Count | Meaning |
|---|---|---|
| `have` | 3 | `PsiOutput`, `PsiBaseCase`, `PsiName` — the markers |
| `bindable` | **72** | BusinessMath 2.14.0 has the mathematics; needs an Excel-facing binding |
| `new` | 57 | no mathematics upstream — `provider` says `absent from BusinessMath 2.14.0` |
| `not ours` | 12 | role declarations rather than functions |
| `unreviewed` | 151 | statistics and run-reporting, which need a simulation engine, not a distribution |

**All 113 distribution rows are now resolved: 56 bindable, 57 absent.** None is unreviewed, which
is the part that matters — the distribution surface is the mathematics, and it is now known
either way.

The nine distributions the corpus actually calls — `PsiBernoulli`, `PsiNormal`, `PsiLogNormal`,
`PsiTriangular`, `PsiDiscrete`, `PsiUniform`, `PsiBinomial`, `PsiIntUniform`, `PsiPoisson` — are
**all bindable**, covering 1,166 of the family's 1,950 corpus calls. Nothing upstream blocks the
first pass.

The 57 absent rows are recorded in **`project/plans/psi_upstream_gaps.md`** and its joinable
`psi_upstream_gaps.tsv`, because nothing upstream records them: BusinessMath's work list was
scoped from the corpus, and of these 57 names **zero** appear in it. Not attempted and missed —
never in scope.

52 are BusinessMath's and 5 are ours (`PsiSip`, `PsiSlurp`, `PsiTSSip`, `PsiCertified`, `PsiVary`
name a stored data object rather than computing anything — address arithmetic, which upstream's
own proposal assigns downstream). The 52 collapse to roughly **twenty** pieces of work: one
percentile-fitting solve covering all 28 `*Alt` rows, two process families covering 7 time-series,
and seventeen individual distributions.

**The corpus calls none of the 57.** This is a completeness list, not a blocker list.

`have` is not self-reported. The matrix is reconciled against `FunctionRegistry` itself —
every group's `all`, plus the alias table, which is why `STDEV.S` counts as covered by whatever
covers `STDEVS`. A function is `have` when the registry answers to its name and nothing else.

Two columns are **not** maintained that way. `calls` and `books` are the scaffold-time corpus
scan, and the recent census disagrees with them — `PsiBaseCase` reads 95/7 here and 129/6 there.
Treat them as an ordering hint for what to do next, not as a measurement. Refreshing them needs a
full-corpus census, which currently traps partway through.

---

## Priorities

1. ~~**Extract the 73 unchanged**, with their tests, before adding anything.~~ **Done** in 0.1.0.
2. ~~**Bind the statistical block.**~~ **Done.** The dotted spellings landed; `STDEV.S`, 86,410
   corpus calls and reachable from no formula at the time, now resolves.
3. ~~**Bind the Psi distributions**, each with a fixed-seed signature test.~~ **Done.** 111 of
   Frontline's 296 answer, including every distribution the corpus calls.
4. **Resolve the 266 unreviewed.** In progress. Asked the live registry: **0 of 286 already
   answered**, so the label was honest and none was secretly covered. Twenty math primitives have
   landed since; the plan's expectation that most is *"math, engineering and text — largely
   Foundation, libm and swift-numerics"* held exactly.
5. **Compare against Excel, not against ourselves.** ADR-001. A test whose expected value came
   from reading a specification proves only that we read it the same way twice.
6. **Test the seams.** Three real bugs in one afternoon lived exactly where two packages meet.
   Six more came out of running against real Risk Solver workbooks rather than fixtures — see
   Current Status — and every one of them was invisible to a hand-written test.
7. **Correctness over coverage.** A function that is registered and wrong scores the same as one
   that is registered and right, so the count is not the measure it looks like.
8. **Measure before building, and record the number where the decision is.** The habit that has
   paid most. 118× said lowering was worth writing; the corpus histogram named `NPV` as one rule
   worth 10 of 13 refusals; 33% said the `consistency` checker must not ship enabled. None of
   those was guessable, and each is recorded beside the thing it decided.

---

## Roadmap

Three workstreams. They are genuinely independent except at one point, and that point orders
everything.

```
  coverage ──────────────────────────► the oracle checker ──► the CLI
  (the registry)                            ▲
                                            │ needs a correct evaluator
  simulation ─── done ─────────────────────┘
  validator  ─── structural checkers ──────┘
```

**The dependency worth naming:** the validator's most valuable check is the oracle — Excel caches
a value for every formula cell, so recomputing and comparing says where a *workbook* disagrees
with itself. That is a claim no other tool can make, and it is only true where our evaluator is
right. So the oracle checker is gated on coverage, and coverage is therefore the critical path to
the motivating application rather than an end in itself.

### Shipped

- **v0.1.0** — the 73, extracted. **v0.2.0** — the statistical block.
- ~~**v0.3.0** — financial and Psi distributions.~~ Half shipped, and the half that landed was
  not the half planned; the shape correction was not on this roadmap at all, because nobody knew
  the lookups were wrong until the corpus made someone look.
- ~~**v0.4.0** — whole-column references.~~ ~~**v0.5.0** — spilling.~~ Both shipped. Note that
  spilling appears below as *"not planned"*; it shipped anyway, on one function's need, and the
  entry stays as written rather than being quietly revised.
- ~~**v0.6.0** — BusinessMath 2.15.0 and the Psi distribution surface.~~ Shipped.
- **v0.7.0** — the simulation stack and the validator. In flight.

### Next

- **v0.8.0 — the unreviewed bucket resolved.** 266 rows, and the categories are not equal:
  **engineering (48)** and **text (32)** are the near-free ones, like math was — base conversion,
  bitwise, `CHAR`/`CODE`/`EXACT`. **statistical (46)** belongs to BusinessMath and is not ours to
  write. **lookup (24), financial (27), database (12)** need judgment per function and are where
  the honest `new` and `out of scope` markings will come from. Success is `unreviewed` reaching
  **0** — every row classified — not every row implemented.
- **v0.9.0 — the oracle checker.** Recompute every formula, compare against Excel's cached value,
  report the disagreements. Gated on v0.8.0, and on hand-triaging its corpus findings: a
  disagreement is a finding only where *we* are right, and the ~0.40% where we are not must never
  be reported as a workbook defect.
- **v1.0 — `xlsx-audit`.** The motivating application, runnable by someone who is not us.

### Carried, unscheduled

- **Common subexpression elimination**, upstream in BusinessMath. `BytecodeOptimizer` folds
  constants and simplifies algebra but does not eliminate common subexpressions, and a cell read
  *k* times is inlined *k* times — measured 1→181→463→34,347 instructions as lowering rules
  landed. Benefits every BusinessMath caller, not only us.
- **Cross-sheet lowering.** The last 17% of real outputs refuse for one reason: `Lowerer` is
  `CellRef`-shaped and they need `CellAddress`.
- **`consistency` below its false-positive rate.** 33% across six real models. It finds real
  defects and stays opt-in until that comes down.
- **Errored trials.** Real models produce outputs where some trials error rather than returning a
  number. They are excluded from the statistics rather than averaged as zero, and nothing yet
  says *which* trials or *why*. That diagnosis is the validator's simulation tier.

Not planned: nothing, currently. ~~Spilling~~ was the last entry here and it shipped.

**The gate that is not corpus-shaped:** for any function, evaluating it must agree with the value
Excel itself recorded. That check works on files nobody has seen, which is the difference between
fitting a corpus and being correct.

---

## Known traps, recorded before they are hit

From Frontline's own documentation, and worth encoding as tests rather than comments:

- `PsiLogNormal(mu, sigma)` takes the **arithmetic** mean and standard deviation of the lognormal
  itself; `PsiLogNorm2` takes the **log-scale** parameters. Swapping them fails silently.
- `PsiTriangular` and `PsiPert` are published as `(a, c, b)` — deliberately not alphabetical.
  Positionally that **is** `(min, likely, max)`. Do not "correct" the letters.
- `PsiNormalSkew(a, b, c)` is `(lower ≈ −3sd, upper ≈ +3sd, skew)`, not `(mean, sd, skew)`.
- `PsiCauchy` and `PsiLaplace` contradict themselves in Frontline's prose about whether argument
  one is location or scale.
- The 28 `Psi*Alt` functions have **no fixed positional signature** — parameters are supplied as
  free-order pairs. Any binding must choose a convention and say so.
- Excel's own `AGGREGATE`, `INDEX` and `LOOKUP` each have two documented forms; the matrix records
  one.

---

**Last Updated:** 2026-09-08 (later still) — Priorities and Roadmap reconciled. The roadmap
listed v0.4.0 and v0.5.0 as future when both had shipped, and named neither the simulation stack
nor the validator. Rewritten around the dependency that actually orders the work: the oracle
checker is the validator's most valuable claim and is only true where the evaluator is right, so
coverage is the critical path to the motivating application rather than an end in itself. Added
priority 8 — measure before building — because it is the habit that has paid most and was not
written down. Spilling's "not planned" entry stays as written, with a note that it shipped anyway.

Earlier: 2026-09-08 (later) — the simulation stack recorded. Current Status
rewritten: it still described v0.5.0's spilling while fifteen public types had shipped
underneath it, which is the same drift this project found in BusinessMath's roadmap on the
same day — a capability shipping without anything prompting the documents to notice. The
source table gains two rows for the simulation layer, and the six defects the real
workbooks found are recorded with what each one was, because "tested against real files"
is a claim and those are the evidence for it.

Earlier: 2026-09-08 — **v0.6.0 released.** BusinessMath 2.15.0 implemented the whole
52-row Psi completeness delta and closed the NASD February rule, the last outstanding source of
corpus disagreement. 50 more distributions bound: 106 of Frontline's 113 distribution rows now
answer, 269 functions registered, 865 tests. Capability map filled in — it had been the unedited
template. Coverage docs moved to `project/plans/proposals/Excel conformance/`.
Earlier: 2026-09-07 — PSI rows reconciled against BusinessMath 2.14.0, which closed its
Risk Solver work list: all 113 distribution rows now resolved (56 bindable, 57 absent upstream),
`bindable` 50 → 72. The dependency moved 2.11.0 → 2.14.0, which fixed the daylight-saving hour in
`actual/360`, `actual/365` and `actual/actual`; three `XCTExpectFailure` guards were removed
because the defect they pinned is gone. The NASD February rule is still open.
Earlier: 2026-09-06 — coverage table reconciled against the live `FunctionRegistry`:
`have` 72 → 160 as the Excel-facing bindings landed, `bindable` 84 → 57, `unreviewed` 347 → 286.
Earlier: created 2026-09-04. Scope and counts from the coverage matrix; nothing
implemented yet.

---

**Last Updated:** 2026-09-05 — added the oracle, the specification suite and ADR-001; earlier for v0.5.0; earlier for v0.4.0; the v0.3.0 note stands. Earlier, reconciled for v0.3.0. Recorded the lookup corrections and why
they happened, added the Array group to the source table, struck the shipped roadmap lines while
noting where 0.3.0 diverged from what was planned, pinned versions corrected, and added
"correctness over coverage" as a priority because this release is the argument for it.
