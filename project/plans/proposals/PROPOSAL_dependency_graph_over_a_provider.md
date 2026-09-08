# Design Proposal: move `DependencyGraph` to SwiftExcelCore

**Status:** Draft for review — SwiftExcelFunctions session, 2026-09-08
**For:** SwiftXLSX and SwiftExcelCore
**Reviewers:** MinLP session (SwiftExcelFunctions), then the package owners
**Measured against:** SwiftXLSX 0.22.0, SwiftExcelCore 0.5.0

**Supersedes** the first draft of this document, which proposed adding a
provider-based initialiser to `DependencyGraph` where it currently lives. That solved
one package's access problem. This removes the reason anyone would ever write a
second graph.

---

## 1. Objective

Move `DependencyGraph` from SwiftXLSX to SwiftExcelCore, with a cell set and a
`CellValueProvider` as its designated initialiser. Leave `init(workbook:)` and
`init(sheet:including:)` behind in SwiftXLSX as an extension over it, and a
`typealias` so existing callers do not change.

**One implementation, in the package whose vocabulary it is already written in.**

---

## 2. Motivation

### 2.1 The initialiser already reads exactly a cell set and a provider

This is the whole proposal in one paragraph. `DependencyGraph`'s designated
initialiser reads **two things** off a `Worksheet`:

```swift
for sheet in sheets {
    for (refString, (value, _)) in sheet.cells {
        inScope.insert(CellAddress(sheet: sheet.name, ref: refString))
    }
}
```

`sheet.name` and `sheet.cells` — a name, and a dictionary from reference to value.
That is **an address set and a value provider**, which is what this proposal asks the
initialiser to take directly. `CellAddress` already carries the sheet name, so the
substitution is `address.sheet` for one and `provider.value(at:inSheet:)` for the
other.

The type was already written against the abstraction. It had simply never been given
it.

### 2.2 The coupling corroborates it

This is the argument, and it is a measurement rather than an opinion. In
`DependencyGraph.swift` at 0.22.0:

```
import SwiftExcelCore            ← the only import

SwiftExcelCore types    65 references   CellAddress 56, CellRef 4, CellValue 3,
                                        CellRange 1, FormulaAST 1
SwiftXLSX types          5 references   Workbook 3, Worksheet 2
```

And the five are not distributed through the logic. They are:

| Line | Reference | What it is |
|---|---|---|
| 8 | `Workbook` | a doc-comment example |
| 54 | `init(workbook:)` | convenience initialiser |
| 79 | `init(sheet:including:)` | convenience initialiser |
| 88 | `init(workbook:including:)` | convenience initialiser |
| 102 | `sheets: [Worksheet]` | the designated initialiser's parameter |

So **four code references, all in initialisers.** The traversal, Kahn's sort, the
cycle detection and the whole-column range intersection are already written entirely
against types that live in SwiftExcelCore.

### 2.3 A dependency graph is not a file-format concern

`CellAddress` and `FormulaAST` live in SwiftExcelCore because they are the shared
vocabulary. A graph over cells is a fact *about a set of cells* — which precedes
which — and holds identically whether they came from an `.xlsx`, a test double, a
generated model, or a sheet held in memory.

Its current home is where it was written, not where it belongs.

### 2.4 The cost of leaving it: a second implementation

SwiftExcelFunctions needs a topological order with cycle detection for a Monte Carlo
trial loop. Depending on SwiftXLSX to get it would put a file-format dependency in
the one package whose stated differentiator is not having one — so the alternative is
writing Kahn's algorithm a second time.

That is a day's work and the wrong day's work: two orders that can disagree, in a
project whose evaluator already relies on the first. Moving the type removes the
reason anyone reaches for that, permanently, rather than for one consumer.

---

## 3. Proposed Architecture

### 3.1 The designated initialiser, in SwiftExcelCore

```swift
public struct DependencyGraph: Sendable {

    /// Builds a graph from a provider and an explicit set of addresses.
    ///
    /// - Parameters:
    ///   - cells: Every address in scope. Supplied rather than discovered — see below.
    ///   - provider: Answers the value at each address.
    public init(cells: [CellAddress], provider: any CellValueProvider)
}
```

Everything else — `evaluationOrder`, `inputs`, `outputs`, `precedents(of:)`,
`dependents(of:)`, `allDependents(of:)`, `isAcyclic`, `cycles`, `GraphError` — is
unchanged.

### 3.2 The scope must be given, not discovered

`CellValueProvider` answers *"what is at this address?"* and cannot be asked *"which
addresses do you have?"*. Its whole surface is address-in, value-out.

The graph needs the opposite. It builds its scope set first — *"an edge can only be
kept once both ends are known to belong"* — which is why the caller supplies it.

This is a claim about the protocol's shape, not about speed. A bounded-range
parameter would paper over it: the only way to turn a range into a cell set through
this protocol is to probe every address in the rectangle. Measured in
`ModelSurveyor`, which had to do exactly that: **34.8s against 1.08s** once the
provider could hand over its keys. A 32× difference, and real models are sparse and
wide, which is the shape that punishes rectangle-scanning hardest.

That figure is *supporting evidence*, not the argument. Read as a performance problem
it invites "add a cache"; the actual problem is that the protocol cannot express the
question.

**There is deliberately no `including:` filter on this initialiser.** The convenience
ones need a filter because they *derive* the set from worksheets and have no other
way to narrow it. This one derives nothing: a caller wanting a subset passes a
subset.

**`any CellValueProvider` rather than `some`**, because a graph is built once per
model and never per trial. Recorded so nobody removes the existential later without
knowing the call frequency.

### 3.3 Workbook scope by default, and one model settles it

`CellAddress` is `(sheet, ref)`, so a caller passing addresses from several sheets
gets a cross-sheet graph and one passing a single sheet's addresses gets the narrow
case. No `sheetScope` parameter is needed: the caller expresses scope by choosing
what to pass.

That default matters. Formulas on a Psi-carrying sheet that reference another sheet,
across six real Risk Solver workbooks:

| Workbook | Cross-sheet | Share | Notes |
|---|---|---|---|
| **Long Acre** | **225 of 326** | **69%** | 20 worksheets, Psi on 1, 126 Psi calls |
| Jeffords (B) | 20 of 74 | 27% | |
| EToys | 0 of 74 | — | |
| Genzyme | 0 of 92, 0 of 104 | — | |
| Reids Raisins | 0 of 17 | — | |
| Vinton Auto | 0 of 24 | — | |

`init(sheet:including:)` documents that a reference outside scope is **"dropped along
with its edge."** For Long Acre — the largest model in the set — a per-sheet graph
therefore drops the precedents of **69% of its formulas**.

That does not error and does not refuse. It returns a topological order that is
*confidently wrong*, and a loop following it evaluates cells before their inputs and
produces numbers nobody can distinguish from correct ones.

### 3.4 What stays in SwiftXLSX

```swift
// SwiftXLSX
public typealias DependencyGraph = SwiftExcelCore.DependencyGraph

public extension DependencyGraph {
    init(workbook: Workbook)
    init(sheet: Worksheet, including: ((CellValue) -> Bool)? = nil)
    init(workbook: Workbook, including: @escaping (CellValue) -> Bool)
}
```

Each becomes a thin adapter: gather the addresses, wrap the sheets in a provider,
call the designated initialiser. `WorkbookValueProvider` already exists and already
conforms, so the wrapping is not new work.

---

## 4. Source Compatibility

The part a reviewer will weigh hardest, so stated plainly.

- **Existing SwiftXLSX callers do not change.** The `typealias` keeps
  `SwiftXLSX.DependencyGraph` resolving, and the three initialisers keep their exact
  signatures.
- **`import SwiftXLSX` continues to be sufficient.** The re-export is deliberate and
  maintained, not incidental: SwiftXLSX carries a file whose entire content is

  ```swift
  // SwiftExcelCoreExports.swift
  @_exported import SwiftExcelCore
  ```

  **And it has already carried two types through exactly this move.** `CellValue` and
  `FormulaAST` live in SwiftExcelCore today; they were in SwiftXLSX before the
  extraction, and `import SwiftXLSX` stayed sufficient throughout. This family has
  done this before, deliberately, with a mechanism built for it.
- **No new dependency edge in any direction.** SwiftXLSX → SwiftExcelCore already
  exists; SwiftExcelFunctions → SwiftExcelCore already exists. Nothing becomes
  cyclic, which is the failure mode the previous draft had to argue around.
- **Semantic version:** a minor for both packages. Nothing is removed and no
  signature changes.

The one visible difference is that `DependencyGraph` becomes constructible without a
`Workbook`, which is the point.

---

## 5. Test Strategy

1. **Equivalence with the existing initialiser.** Build a `Workbook`, take
   `DependencyGraph(workbook:).evaluationOrder`, then build a provider over the same
   cells and assert the orders match. That is the assertion that says this is the same
   graph.

   **Both sides must be given the same scope, and this is easy to get wrong.**
   `init(workbook:)` includes *every* cell — its own documentation says "labels
   included, and a referenced-but-empty cell too, because you still have to visit it
   to learn it is zero." A provider-based caller will often pass only formula cells.
   Hand the two sides different scopes and the orders differ, and the test looks like
   it found a bug in the new initialiser rather than in itself.

2. **The order does not depend on the order the addresses arrive in.** The same
   addresses supplied in a different sequence must produce an identical
   `evaluationOrder`.

   This is the first thing to hand the graph a container whose iteration order is
   unspecified, so the property is newly worth pinning. It holds today —
   `topologicalSort` sorts its in-degree-zero queue by `sortKey` and inserts each
   newly-freed node in sorted position — and everything downstream leans on it: a
   nondeterministic order would silently break seeded reproducibility, which for a
   trial loop means same seed, same numbers, or the design is decoration.

3. **Cross-sheet precedents survive.** A cell on `Sheet2` referencing `Sheet1!A1`
   must order after it — the Long Acre case in miniature.

4. **Cycle detection is unchanged**, including a cycle that closes across two sheets.

5. **The whole existing suite passes unmoved.** The strongest evidence that an
   extraction is behaviour-preserving is that the tests written against the old home
   still pass against the new one, through the `typealias`.

6. **No `Workbook` in at least one test.** A provider built from a plain in-memory
   type, proving the type does what the move exists to enable.

---

## 6. Alternatives Considered

**Add a provider-based initialiser where the type currently lives.** This document's
own first draft. It works and is a smaller change, but it solves one package's access
problem and leaves the type in the wrong place — anyone else wanting an order without
a `Workbook` faces the same question again, and the honest answer stays "depend on the
file-format package or write your own."

**Add `populatedCells()` to `CellValueProvider`** so the graph can discover its own
scope. Worth naming because it is the obvious next thought, and it is not rejected on
blast radius: a protocol requirement with a protocol-extension default is
source-compatible and breaks no conformer.

It is rejected because **the only default anyone could write is the rectangle scan.**
Every conformer would silently inherit a method that compiles, returns the right
answer, and is O(rows × columns) on the sparse-and-wide sheets real workbooks are —
with no signal to override it, because nothing about it is broken. That is precisely
how `ModelSurveyor` reached 34.8 seconds: the method was not missing, the rectangle
scan was the only route available. Shipping it as a default does not close the gap; it
institutionalises it and puts a reassuring name on it.

A parameter has the opposite property: **a caller supplying the set has necessarily
thought about where it came from, and a caller inheriting a default has necessarily
not.**

**A second implementation in SwiftExcelFunctions.** Rejected — §2.4.

---

## 7. Open Questions

1. **`[CellAddress]` or `Set<CellAddress>`?** Cosmetic, and known to be cosmetic: the
   initialiser builds a set immediately, and `topologicalSort` sorts its queue by
   `sortKey`, so the input container's iteration order cannot reach the result. An
   array is marginally easier to write the §5.2 test against. Weak preference for the
   array.

2. **Does `GraphError` move too?** It is nested in the type, so it moves with it, but
   worth confirming nothing else in SwiftXLSX catches it by qualified name.

Resolved during review, recorded so the reasoning is not relitigated:

- **`including:` is dropped from the designated initialiser** — §3.2. The symmetry
  with the convenience initialisers is false; they derive the set, this does not.
- **`any` rather than `some`** — §3.2. Built once per model, never per trial.

---

## 8. What this does *not* unblock

Stated because the first draft implied otherwise and that inflated the case.

**SwiftExcelFunctions' trial loop works today.** Its test target already depends on
SwiftXLSX, so `DependencyGraph(workbook:)` has been reachable from tests the whole
time, and the full pipeline has been run on six real workbooks with it. The loop takes
its evaluation order as a caller-supplied parameter and validates it on entry — every
precedent before its dependent — so a wrong order fails loudly rather than producing
numbers.

So this proposal **removes a duplication rather than unblocking a consumer**, and
should be judged on that.

A second consumer exists and is designed rather than anticipated: the workbook
validator, proposed at `53b853a` in SwiftExcelFunctions. Its §2.2 lists
`DependencyGraph` as a required input for the `recursion` checker — circular
references, which `cycles` already computes — and that is step 1 of its sequencing,
chosen as the cheapest possible first checker.

Its §7 records the open question of the graph's home and says explicitly that the
validator does not depend on the outcome: it imports SwiftXLSX regardless, because it
reads files. So it is a second consumer for whichever shape wins, not a second vote
for this one.

A proposal with a working fallback is a weaker claim on urgency and a stronger one on
merit.
