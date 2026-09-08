# Design Proposal: `DependencyGraph` over a `CellValueProvider`

**Status:** Draft for review — SwiftExcelFunctions session, 2026-09-08
**For:** SwiftXLSX
**Reviewers:** MinLP session (SwiftExcelFunctions), then SwiftXLSX
**Measured against:** SwiftXLSX 0.22.0, SwiftExcelCore 0.5.0

---

## 1. Objective

Add one initialiser to `DependencyGraph` that builds a graph from a
`CellValueProvider` and an explicit set of `CellAddress`, so a caller can obtain a
topological evaluation order **without a `Workbook`**.

This is an initialiser over existing API, not a redesign. Nothing about the graph, its
traversal, its cycle detection or its public surface changes.

---

## 2. Motivation

### 2.1 The consumer, and why it cannot use what exists

SwiftExcelFunctions is building a Monte Carlo trial loop over a recognised model. A trial
loop needs a topological evaluation order over the model's cells, with cycle detection.
`DependencyGraph` already computes exactly that.

It cannot be reached. Every initialiser takes a `Worksheet` or a `Workbook`:

```swift
public init(workbook: Workbook)
public init(sheet: Worksheet, including: ((CellValue) -> Bool)? = nil)
public init(workbook: Workbook, including: @escaping (CellValue) -> Bool)
```

Depending on those from SwiftExcelFunctions would put a **file-format dependency in the one
package whose stated differentiator is not having one**. The evaluator works against
`CellValueProvider` precisely so it can evaluate a sheet that never came from a file — a test
double, a generated model, a sheet held in memory. The graph is the one piece of ordering
machinery it needs and the one piece it cannot use.

### 2.2 Why a second topological sort is the wrong answer

Writing Kahn's algorithm again inside SwiftExcelFunctions is a day's work and the wrong day's
work: two orders that can disagree, in a project whose evaluator already relies on the first.
That is the duplication the package split exists to prevent, and it is why this proposal exists
rather than a local implementation.

### 2.3 Scope must be the workbook, and one model settles it

The obvious shape — mirror `init(sheet:including:)` and take one sheet's worth of cells — is
wrong, and the corpus is emphatic about it. Formulas on a Psi-carrying sheet that reference
another sheet, across six real Risk Solver workbooks:

| Workbook | Cross-sheet | Share | Notes |
|---|---|---|---|
| **Long Acre** | **225 of 326** | **69%** | 20 worksheets, Psi on 1, 126 Psi calls |
| Jeffords (B) | 20 of 74 | 27% | |
| EToys | 0 of 74 | — | |
| Genzyme | 0 of 92, 0 of 104 | — | |
| Reids Raisins | 0 of 17 | — | |
| Vinton Auto | 0 of 24 | — | |

`init(sheet:including:)` documents that a reference outside scope is **"dropped along with its
edge."** For Long Acre — the largest model in the set — a per-sheet graph therefore drops the
precedents of **69% of its formulas**.

That does not error and does not refuse. It returns a topological order that is *confidently
wrong*, and a trial loop following it evaluates cells before their inputs and produces numbers.
Numbers nobody can distinguish from correct ones.

So: **workbook scope by default, per-sheet as the narrower case.** `CellAddress` is already
sheet-qualified, so this costs nothing — see §3.2.

---

## 3. Proposed Architecture

### 3.1 The gap is enumeration, not performance

`CellValueProvider` answers *"what is at this address?"* and cannot be asked *"which addresses
do you have?"*. Its whole surface is address-in, value-out:

```swift
func value(at ref: CellRef) -> CellValue?
func value(at ref: CellRef, inSheet: String) -> CellValue?
func lastPopulatedCell() -> CellRef?
```

`DependencyGraph`'s designated initialiser needs the opposite. It builds its scope set first —
*"an edge can only be kept once both ends are known to belong"* — by iterating `sheet.cells`,
the dictionary a `Worksheet` holds and a provider does not.

**So the caller must supply the cell set.** That is the proposal's central claim, and it is a
claim about the protocol's shape rather than about speed.

A bounded-range parameter would paper over this: the only way to turn a range into a cell set
through this protocol is to probe every address in the rectangle. Measured on the six workbooks
above, in `ModelSurveyor`, which had to do exactly that: **34.8s against 1.08s** once the
provider could hand over its keys. A 32× difference, and real models are sparse and wide, which
is the shape that punishes rectangle-scanning hardest.

That figure is *supporting evidence*, not the argument. Read as a performance problem it invites
"add a cache"; the actual problem is that the protocol cannot express the question.

### 3.2 The proposed initialiser

```swift
public extension DependencyGraph {

    /// Builds a graph from a provider and an explicit set of addresses.
    ///
    /// - Parameters:
    ///   - cells: Every address in scope. Supplied rather than discovered, because
    ///     `CellValueProvider` has no enumeration — and because scope has to be known
    ///     before the graph is built, not filtered afterwards.
    ///   - provider: Answers the value at each address.
    ///   - including: An optional filter, matching the existing initialisers.
    init(
        cells: [CellAddress],
        provider: any CellValueProvider,
        including: ((CellValue) -> Bool)? = nil
    )
}
```

**Workbook scope falls out for free.** `CellAddress` is `(sheet, ref)`, so a caller passing
addresses from several sheets gets a cross-sheet graph, and one passing a single sheet's
addresses gets the narrow case. The existing `sheetScope` parameter has no analogue here and
needs none: the caller expresses scope by choosing what to pass. That is the same principle
`init(sheet:including:)`'s own documentation states — scope goes in *before* the graph is built,
because filtering afterwards is too late for both the order and the cycle set — applied one layer
out.

### 3.3 Why this is an initialiser and not a redesign

Everything the graph reads already exists on the provider side:

- **`CellValue` already carries its formula.** `indirect case formula(FormulaAST, cached:)`, with
  a public `formulaAST` accessor. The graph needs the AST to find precedents; it is already there.
- **`CellAddress` already lives in SwiftExcelCore**, which SwiftXLSX and SwiftExcelFunctions both
  depend on. No type needs a new home and no vocabulary is added.
- **The designated initialiser already takes a flat cell set internally.** It builds `inScope`
  first and then walks it. This initialiser supplies that set directly instead of deriving it
  from `[Worksheet]`.

Reviewers weighing cost should weigh it against that: the traversal, the cycle detection, the
range intersection for whole-column references, and the public surface are all untouched.

---

## 4. Constraints & Compliance

- **No new dependency, in either direction.** This lives in SwiftXLSX and reads only
  SwiftExcelCore types. Critically, SwiftXLSX must **not** depend on SwiftExcelFunctions: the
  package graph runs SwiftXLSX → SwiftExcelCore and SwiftExcelFunctions → both, and adding an
  edge back would make it cyclic. A duplicated one-method protocol is the smaller problem.
- **Sendable.** `any CellValueProvider` is already `Sendable`-constrained by the protocol.
- **Whole-column references.** The existing initialiser intersects any range over 4,096 cells
  with the cells that exist, so `$B:$G` does not expand to 6.3 million addresses. That logic is
  reused unchanged; it operates on the scope set, which this initialiser supplies.

---

## 5. Test Strategy

1. **Equivalence with the existing initialiser.** Build a `Workbook`, take
   `DependencyGraph(workbook:).evaluationOrder`, then build a provider over the same cells and
   assert the orders match. That is the assertion that says this is the same graph.
2. **Cross-sheet precedents survive.** A cell on `Sheet2` referencing `Sheet1!A1` must order
   after it — the Long Acre case in miniature, and the one a per-sheet graph gets wrong.
3. **Cycle detection is unchanged**, including a cycle that closes across two sheets.
4. **No `Workbook` in the test.** At least one test builds its provider from a plain in-memory
   type, proving the initialiser does what it exists to do.

---

## 6. Alternatives Considered

**A bounded-range parameter instead of a cell set.** Rejected — §3.1. It converts an
expressiveness gap into a performance cliff and hides it behind a plausible-looking API.

**Add enumeration to `CellValueProvider` in SwiftExcelCore.** Defensible and possibly better
long-term, and it is the one alternative worth a reviewer's attention. Rejected *for now* because
it changes a protocol with existing conformers outside this proposal's blast radius, where taking
the set as a parameter changes nothing for anyone. If SwiftExcelCore later grows a
`populatedCells()`, this initialiser becomes a convenience over it rather than being replaced.

**A second topological sort in SwiftExcelFunctions.** Rejected — §2.2.

**Do nothing; let consumers pass a hand-built order.** This is what the consumer is doing *now*,
and it works: the trial loop takes the order as a parameter and validates it on entry, so a wrong
order is caught rather than silently producing numbers. It is a good fallback and a poor
destination — every consumer that wants a real workbook's order still has to reach a `Workbook`
to get one.

---

## 7. Open Questions

1. **Should `cells` be `[CellAddress]` or `Set<CellAddress>`?** The initialiser builds a set
   immediately. An array preserves a caller's ordering, which is meaningless to the graph but
   makes the equivalence test in §5.1 easier to write. Weak preference for the array; no strong
   view.
2. **Should the provider be `some CellValueProvider` rather than `any`?** Generic avoids the
   existential, which matters if this is ever called per-trial rather than per-model. The current
   consumer builds the graph once, so it does not matter here.
3. **Is `including:` wanted at all?** It exists on the other initialisers for symmetry, but a
   caller who already chooses the address set can filter there instead. Included for consistency;
   easy to drop.

---

## 8. The consumer

SwiftExcelFunctions' trial loop is being built now, with the evaluation order as a
**caller-supplied parameter** so it does not block on this proposal. The order is validated on
entry — every precedent must appear before its dependent — so a wrong order fails loudly rather
than producing numbers.

If this lands, that path gets a real workbook's order without a file-format dependency, and
nothing in the consumer has to change. So the proposal has a working consumer at review time
rather than a hypothetical one, and a fallback if it is declined.
