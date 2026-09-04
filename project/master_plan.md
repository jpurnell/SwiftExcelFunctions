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

`SwiftExcelCore` resolves by path until it is tagged; both dependencies become pinned versions at
first release.

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
| Foundation, swift-numerics | trigonometry, logs, rounding, dates, text, complex | primitives |
| **BusinessMath** | distributions, statistics, financial, Risk Solver | where a second implementation could disagree |

Excel's sign conventions are applied **here**, at the binding — BusinessMath returns positive
where Excel returns negative, and the flip belongs in the translation, not the mathematics.

---

## Current Status

**v0.1.0 — released 2026-09-04.** The 73 functions, the registry and the evaluator arrived by
extraction from SwiftXLSX. 546 tests, gate 45/45 at 0/0. Dependencies pinned: SwiftExcelCore
0.1.0, BusinessMath 2.9.0, and SwiftXLSX 0.13.0 for tests only.

Against Microsoft's 519 documented worksheet functions:

| Marking | Count | Meaning |
|---|---|---|
| `have` | **72** | implemented in SwiftXLSX today; moves here unchanged |
| `bindable` | **84** | BusinessMath computes it; needs an Excel-facing binding |
| `new` | 6 | verified absent everywhere |
| `out of scope` | 10 | cube and web — need an OLAP connection or the network |
| `unreviewed` | 347 | no evidence either way; **not** the same as absent |

Risk Solver's 295 PSI functions: **50 bindable**, 13 that are role declarations rather than
functions, 232 unreviewed.

---

## Priorities

1. **Extract the 73 unchanged**, with their tests, before adding anything. A working baseline
   makes every later diff readable.
2. **Bind the statistical block.** 51 functions, no new mathematics, and it includes the dotted
   spellings every workbook saved since Excel 2010 uses. `STDEV.S` alone is 86,410 calls in the
   measured corpus and is reachable from no formula today.
3. **Bind the financial 11 and the Psi distributions**, each with a fixed-seed signature test.
   This is where a wrong binding does real damage.
4. **Review the 347 unreviewed** before treating any of it as new work. Most is math, engineering
   and text — largely Foundation, libm and swift-numerics — so a large share should resolve to
   near-free.

---

## Roadmap

- **v0.1.0** — the 73, extracted, tests passing, gate clean.
- **v0.2.0** — the statistical block bound.
- **v0.3.0** — financial and Psi distributions, fixed-seed tested.
- **v0.4.0** — the unreviewed bucket resolved into `have` / `bindable` / `new`.

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

**Last Updated:** 2026-09-04 — created. Scope and counts from the coverage matrix; nothing
implemented yet.
