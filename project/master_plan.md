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

Excel's sign conventions are applied **here**, at the binding — BusinessMath returns positive
where Excel returns negative, and the flip belongs in the translation, not the mathematics.

---

## Current Status

**v0.5.0 — released 2026-09-05.** Spilling.

- [x] `FormulaEvaluator.spill` — one formula, evaluated once, filling a span
- [x] Four integration tests carrying an array formula out to a file and back
- [x] 662 tests, gate 45/45 at 0/0

The last piece, and it needed no new dependency: evaluation produces an assignment,
SwiftXLSX applies one. Writing the integration test found three gaps that neither
package's own tests could — the two halves did not compose, array formulas were not
discoverable from outside, and a cached error vanished on save.

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

Risk Solver's 295 PSI functions: **3 have** (`PsiOutput`, `PsiBaseCase`, `PsiName` — the markers),
**50 bindable**, 12 that are role declarations rather than functions, 230 unreviewed.

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
3. **Bind the Psi distributions**, each with a fixed-seed signature test. This is where a wrong
   binding does real damage, and it is the only block left outside the registry.
4. **Review the 347 unreviewed** before treating any of it as new work. Most is math, engineering
   and text — largely Foundation, libm and swift-numerics — so a large share should resolve to
   near-free.
5. **Compare against Excel, not against ourselves.** ADR-001. A test whose expected value came
   from reading a specification proves only that we read it the same way twice. Every expected
   value is quoted from a published example or computed from a documented formula.
6. **Test the seams.** Three real bugs in one afternoon lived exactly where two
   packages meet, where each half was self-consistent and neither suite could see the
   other. `SpillIntegrationTests` is the only place that holds both, and it earned its
   keep on the day it was written.
7. **Correctness over coverage.** 0.3.0 found three shipped functions answering wrongly while the
   coverage number said 99.93%. A function that is registered and wrong scores the same as one
   that is registered and right, so the count is not the measure it looks like.

---

## Roadmap

- **v0.1.0** — the 73, extracted, tests passing, gate clean.
- ~~**v0.2.0** — the statistical block bound.~~ Shipped.
- ~~**v0.3.0** — financial and Psi distributions, fixed-seed tested.~~ **Half shipped, and the
  half that landed was not the half planned.** The financial bindings arrived, along with the
  shape correction — which was not on this roadmap at all, because nobody knew the lookups were
  wrong until the corpus made someone look. Psi remains.
- **v0.4.0** — the Psi distributions, fixed-seed tested.
- **v0.5.0** — the unreviewed bucket resolved into `have` / `bindable` / `new`.

Not planned: **spilling**, the mechanism that would write a multi-cell result back across cells.
`TRANSPOSE` is the only shipped function that would want it, and every corpus use of it is a
top-level spill — so the feature is real but reaches almost nothing, and it is a large change to
the evaluator's contract. Worth revisiting if a second function needs it.

**The gate that is not corpus-shaped:** for any function, evaluating it must agree with the value
Excel itself recorded. Excel stores a cached result for every formula cell, so a workbook is a
test oracle. That check works on files nobody has seen, which is the difference between fitting a
corpus and being correct.

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

**Last Updated:** 2026-09-06 — coverage table reconciled against the live `FunctionRegistry`:
`have` 72 → 160 as the Excel-facing bindings landed, `bindable` 84 → 57, `unreviewed` 347 → 286.
Earlier: created 2026-09-04. Scope and counts from the coverage matrix; nothing
implemented yet.

---

**Last Updated:** 2026-09-05 — added the oracle, the specification suite and ADR-001; earlier for v0.5.0; earlier for v0.4.0; the v0.3.0 note stands. Earlier, reconciled for v0.3.0. Recorded the lookup corrections and why
they happened, added the Array group to the source table, struck the shipped roadmap lines while
noting where 0.3.0 diverged from what was planned, pinned versions corrected, and added
"correctness over coverage" as a priority because this release is the argument for it.
