# Design Proposal: A workbook validator — auditing a spreadsheet the way we audit code

**Status:** proposal, 2026-09-08. Phase 0 (Design).
**Motivated by:** `master_plan.md`, which names this as the project's reason for existing —
*"a workbook-correctness CLI, which is the motivating application: read a model, recompute it,
and report where it disagrees with itself."*

---

## 1. Objective

**Point it at an `.xlsx` and have it tell you what is wrong with the model.**

Not whether the file parses. Whether the *model* is sound: cells that disagree with their own
cached values, a formula in a row that differs from its neighbours, a circular reference, a cell
computed and never used, a division with nothing guarding the denominator, a simulation with no
seed.

---

## 2. Motivation

### 2.1 The premise, borrowed from the quality gate

The gate's premise is that **structure is auditable without running anything**. It reads Swift as
a syntax tree and finds recursion without a base case, a symbol nothing reaches, a pointer
escaping its block — none of which requires executing the program.

A workbook has the same shape. Every formula is a `FormulaAST`. The workbook is a graph of them
with a dependency edge set. That is a module of functions and a call graph, and the same class of
finding is available: a circular reference, an unreachable cell, an inconsistent row.

### 2.2 What already exists

This is assembly, not invention. Every input is built and tested:

| Piece | Where | What it gives |
|---|---|---|
| `FormulaAST` | SwiftExcelCore | the tree |
| `CellValue.formula(_, cached:)` | SwiftExcelCore | **the formula and what Excel last computed for it** |
| `DependencyGraph` | SwiftXLSX (see §7) | topological order, `cycles`, `precedents`, `dependents` |
| `FormulaEvaluator` | SwiftExcelFunctions | recomputation, 160 functions |
| `PsiRecognizer.visitFunctionCalls` | SwiftExcelFunctions | the AST visitor |
| `InterpretedRun.referencedCells` | SwiftExcelFunctions | precedent extraction, range-clipped |
| `ModelSurveyor` | SwiftExcelFunctions | uncertain cells, outputs |
| `InterpretedRun` | SwiftExcelFunctions | the trial loop |

### 2.3 The oracle nobody else has

**Excel caches a value for every formula cell.** `ExcelOracleTests` already exploits this — 155,897
comparable cells at 99.60% agreement — but only as a test of *our* evaluator.

Turned around, it is a test of *the workbook*. Where our recomputation and Excel's cached value
disagree and our evaluator is right, the workbook is stale, or its formula was edited without
recalculation, or it depends on something volatile. That is a finding no other tool can make,
because no other tool has both a correct evaluator and the cached values in one place.

The honesty requirement is severe and stated up front: a disagreement is only a finding if our
evaluator is right, and the 0.40% where it is not must not be reported as workbook defects. §5.2.

---

## 3. Proposed Architecture

A **new executable target**, `xlsx-audit`, over a library target `WorkbookAudit`.

```
  .xlsx ──► Workbook ──► WorkbookAudit ──► [Finding] ──► reporters
              │              │
              │              ├── structural checkers   (AST + graph, no evaluation)
              │              ├── oracle checker        (recompute vs cached)
              │              └── simulation checkers   (needs a run)
              ▼
         DependencyGraph
```

Separate targets because the library is what a GUI or a CI job embeds, and the executable is what
a person runs. The library never prints.

### 3.1 A finding

```swift
public struct Finding: Sendable, Equatable {
    public enum Severity: Sendable { case error, warning, note }

    public let checker: String            // "consistency", "unreachable"
    public let severity: Severity
    public let address: CellAddress       // where
    public let summary: String            // one line
    public let detail: String?            // the reasoning, when it needs one
    public let related: [CellAddress]     // the neighbours a consistency finding compares against
}
```

`related` earns its place: the most valuable findings here are *comparative*. "This cell differs
from the eleven beside it" is only actionable if it names the eleven.

### 3.2 A checker

```swift
public protocol WorkbookChecker: Sendable {
    static var name: String { get }
    /// What this checker needs, so the runner only does expensive work someone asked for.
    static var requires: Requirement { get }
    func check(_ model: AuditModel) -> [Finding]
}

public enum Requirement: Sendable {
    case structure       // ASTs and the graph
    case recomputation   // + evaluating every formula once
    case simulation      // + a trial run
}
```

`requires` is the load-bearing part of this design. Structural checks are milliseconds;
recomputation is a pass over every formula; a simulation is thousands of passes. A run that only
wants `consistency` must not pay for a Monte Carlo.

---

## 4. Capabilities — the checker analogues

Of the gate's 41 checkers, roughly nine have real workbook analogues. The rest
(`pointer-escape`, `concurrency`, `memory-*`, `keychain-secrets`, `hig-auditor`) have none, and
saying so is part of the design: this is not a port.

### Tier 1 — the ones worth building first

**`consistency` — the inconsistent formula in a row.** *The single most valuable check here.*
The classic spreadsheet defect is one cell in a range that differs from its neighbours: the copy
that stopped short, the hand-edit nobody noticed. Excel flags a weak version of it.

Detecting it properly means comparing ASTs **modulo relative offset** — normalising each formula
to R1C1 form, where `=B2*C2` in row 2 and `=B3*C3` in row 3 are the *same* formula. Then a run of
cells sharing one normalised AST, with one member differing, is a finding — and `related` names
the run it broke.

This is the check that catches real financial-model errors, and it needs no evaluation at all.

**`recursion` — circular references.** `DependencyGraph.cycles` already computes them, with the
cycle path. This is a reporter over existing output.

**`fp-safety` — unguarded division.** `.divide(_, denominator)` where the denominator is a cell
reference with nothing testing it for zero. The corpus's `#DIV/0!` population is the evidence
that this happens; the finding is the cells that *would* if their inputs moved.

**oracle — recomputation against the cached value.** §2.3. Its own checker rather than an
analogue, and the one nobody else can offer.

### Tier 2

**`unreachable` — cells computed but reaching no output.** `allDependents` from each cell; if it
reaches nothing marked as an output or read by a statistic, it is dead weight. Weaker than the
Swift analogue because a spreadsheet's "output" is often just the cell a human looks at, so this
is a `note`, not a `warning`.

**`duplication` — the same subtree copy-pasted rather than referenced.** An identical normalised
AST appearing in unrelated places, where a named cell would have done. Same normalisation as
`consistency`, opposite conclusion.

**`complexity` / `legibility` — nesting depth and formula length.** A 400-character nested `IF` is
a defect whoever wrote it.

**`smells` — magic numbers.** A literal appearing in many formulas that should have been one cell.
`0.0825` in nineteen places is a tax rate waiting to change.

### Tier 3 — simulation-dependent

**`stochastic-determinism` — a model that draws without a recorded seed.** Directly analogous, and
this project already takes the position: `RandomSource` has no default *by construction*.

**errored trials.** The end-to-end run reports outputs where some trials produced errors rather
than numbers. Nothing yet says *which* trials or *why*. That diagnostic is this tool's job and it
is the first thing to build in this tier, because it is the one finding we already know exists in
real models and cannot currently explain.

---

## 5. Test Strategy

**Fixtures with known defects.** A workbook built in code with one inconsistent formula in a
column, one circular reference, one unguarded division. Each checker finds its own and nothing
else — the false-positive half matters more than the true-positive half, because a validator
nobody trusts is a validator nobody runs.

**The real corpus, as a false-positive census.** Run every checker across the 2,236-workbook
corpus and count findings per checker per workbook. A checker firing on 80% of real models is
wrong about what it is measuring, whatever its logic says. This is the number that decides which
Tier 1 checks ship enabled.

**The oracle checker gets the strictest treatment.** It must not report a workbook defect where
the disagreement is ours. Every finding it makes on the corpus is triaged by hand before the
checker ships, and the known-divergent cases — the daylight-saving day counts, the NASD February
rule — are excluded by name rather than by tolerance.

**Determinism.** The same workbook produces the same findings in the same order. Findings sort by
address; the sheet order comes from the workbook, not a dictionary.

---

## 6. Reusing the quality gate: no, and it does not matter

`quality-gate` is a separate binary whose auditors are SwiftSyntax over Swift source. Its config
(`.quality-gate.yml`) selects and configures fixed checkers — `excludedCheckers`,
`enabledCheckers`, per-checker keys — and exposes no plugin mechanism. There is no way to register
a checker that reads `.xlsx`.

Nor should there be. Making a general Swift quality tool depend on a spreadsheet library to serve
one project would be the wrong trade for both.

**What transfers is the taxonomy, not the code.** The gate's checker names are a vocabulary for
kinds of defect, and reusing that vocabulary means a finding here reads the same way as a finding
there. Three things worth copying deliberately:

- **Zero tolerance, and no suppression.** The gate's rule that a warning is fixed rather than
  silenced is the reason it works. Same here: no `// audit:ignore` in cell comments.
- **A checker that skips is not a checker that passed.** The gate says this in its own output and
  it is the failure mode a workbook auditor will otherwise fall into constantly, since so many
  checks depend on a model shape not every workbook has.
- **Findings carry their reasoning.** Not "inconsistent formula" but which cells it was compared
  against and what the difference was.

Emitting a machine-readable report is worth having so CI can gate on it — but that is a format
decision, not a dependency.

---

## 7. Dependencies, and one question this proposal does not settle

`WorkbookAudit` needs SwiftExcelCore, SwiftExcelFunctions, SwiftXLSX, and BusinessMath for the
simulation tier. The dependency runs one way and adds no edge.

**`DependencyGraph`'s home is open.** It currently lives in SwiftXLSX, imports only
SwiftExcelCore, and uses Core types 65 times against 5 references to `Workbook`/`Worksheet` — all
in convenience initialisers. Moving it to SwiftExcelCore with a provider-and-cell-set designated
initialiser, leaving the workbook conveniences in SwiftXLSX as an extension, would mean nobody
ever writes a second one. That is a separate proposal and this one does not depend on its outcome:
the validator imports SwiftXLSX regardless, because it reads files.

---

## 8. Open Questions

1. **Is R1C1 normalisation enough for `consistency`?** Two formulas that differ only in an
   absolute-vs-relative marker are arguably the same shape and arguably not — `$B$1` deliberately
   pinned is a different intent from `B1` that happened not to move. Needs a corpus census before
   choosing.
2. **What is a "run" for `consistency`?** A contiguous span in one row or column is obvious. A
   rectangular block is probably right. A discontiguous set almost certainly is not. The corpus
   should decide it rather than taste.
3. **How much does the oracle checker cost on a large workbook?** It recomputes every formula
   once. The interpreted path measured 493 ns per propagation operation, so a 50,000-formula model
   is tens of milliseconds — probably fine, and worth measuring rather than assuming.
4. **Should findings be addressable per sheet or per workbook?** Cross-sheet models are common
   — measured, 2 of 6, with the largest at 69% cross-sheet references — so findings need
   `CellAddress`, not `CellRef`. That is decided; what is open is whether the *reports* group by
   sheet.

---

## 9. Sequencing

| # | Deliverable | Ends when |
|---|---|---|
| **1** | `WorkbookAudit` target, `Finding`, `WorkbookChecker`, and `recursion` over `DependencyGraph.cycles` | A real workbook produces a real finding. One checker, end to end |
| **2** | The false-positive census harness | Every subsequent checker has a number before it ships |
| **3** | `consistency` with R1C1 normalisation | It finds the planted defect and does not fire across the corpus |
| **4** | `xlsx-audit` executable and a report format | Someone who is not us can run it |
| **5** | The oracle checker, hand-triaged | Its corpus findings are workbook defects, not ours |
| **6** | Tier 2, then the simulation tier starting with errored-trial diagnosis | — |

Step 2 before step 3 is the point. A checker built without a false-positive number is a checker
that ships noisy and gets disabled.

---

**Next action:** step 1. `recursion` is the cheapest possible first checker — `DependencyGraph`
already computes the cycles — so it exercises the whole path, from file to finding, without any
new analysis to get wrong.
