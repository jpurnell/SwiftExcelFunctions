# Design Proposal: A workbook keeps its defined names

**Date:** 2026-09-16
**Status:** Proposed — awaiting approval
**Category:** api · upstream (SwiftXLSX)

> **Where this lands.** The defect and the fix are in SwiftXLSX's writer. The proposal lives
> here because this is where the corpus evidence is and where the decision is being taken;
> implementation is upstream, and heads the batch of five reader/writer defects this
> corpus work has found.

---

## 1. Objective

**Objective:** A workbook read by this family and written back out keeps its defined names —
all of them, as they were.

**Master Plan Reference:** not on the roadmap. It surfaced from the `LAMBDA` measurement
work, and it outranks most of what *is* on the roadmap, for the reason in §2.

---

## 2. Motivation

**Current situation.** SwiftXLSX's reader parses `<definedName>` into `NamedRange` values and
the evaluator resolves against them. **The writer emits none.** There is no `definedNames`
element in anything it produces.

So a workbook that goes through this family and comes back out has **an empty Name Manager**.

**Why this outranks the other four upstream defects.** They are read-path bugs: they make us
wrong about a formula, and the cost is a bad answer we can measure and fix. This one
*destroys the user's work*. Names are not incidental to a serious workbook — they are the
structure an advanced author builds deliberately:

```
amounts         = Expenditures!$D:$D
categoryFood    = Definitions!$B$53
lookupCategory  = Definitions!$B$19:$C$51
maxEXP          = LAMBDA(arr, y, MAX(arr)^y)
```

Those four shapes are all from real files in the corpus. The fourth is the sharpest: once
`LAMBDA` lands, a name *is* a function the user wrote, and dropping it deletes their code.

**Who this hurts.** Only someone who uses named ranges — which is to say, only the people
likely to come near a project like this one. A template with a `Definitions` sheet and a
populated Name Manager is precisely what an advanced Excel user builds, and handing it back
stripped is worse than refusing to write the file at all: the loss is silent and the file
looks fine.

**Measured across 2,240 workbooks:**

| | |
|---|---|
| Workbooks with at least one defined name | **1,022** — 45% |
| Names in total | **161,901** |
| Median per workbook | **10** (5, among the 812 with a hundred or fewer) |
| Hidden (`hidden="1"`) | **74,992 — 46% of all names** |
| Built-in (`_xlnm.*`) | 1,821 |
| Whole-column references | 3,886 |
| Containing a `LAMBDA` | 3 |

And the extremes say who this is for:

```
47,106   GoldmanSachs_CMCSAModel_Jul_28_2017.xlsx
15,179   Tencent Model - GS 3.19.14.xlsx
 4,887   Project Chaos - Operating Model_v70.xlsx
```

A sell-side equity model with **forty-seven thousand defined names** is not a corner case of
the format; it is what the format is *for*, built by exactly the sort of author who would
come near a library like this one. Reading one of those and writing it back would return a
file that opens perfectly and has had its entire skeleton removed.

**The 46% hidden figure is the one that changes the design**, not the headline. See §12.

**Where it bites today, before anyone writes a file on purpose:** `conformance-workbook`
cannot emit a workbook with names in it, which is why the recursion-limit sheet had to ask
its reader to add two by hand — and the two rounds that cost are documented in
`ExcelEvaluationLimits.md` §5.

---

## 3. Proposed Architecture

**Modified (SwiftXLSX)**

- `Reader/WorkbookXMLParser.swift` — `DefinedNameInfo` keeps every attribute, not three.
- `Reader/WorkbookReader.swift` — hands the raw records to the workbook alongside the
  resolved `NamedRange`s.
- `Workbook.swift` — stores the raw records; gains a public way to add a name.
- `Workbook.swift` (writer) — emits `<definedNames>` in its schema position.

**Unchanged**

- `SwiftExcelCore`. `NamedRange`, `NamedRangeTarget` and `NameScope` are what the *evaluator*
  needs, and nothing here changes that. See §12 for the alternative that would have changed
  them, and why it is worse.

### 3.1 Two representations, on purpose

| | What it is | Who uses it |
|---|---|---|
| `NamedRange` | the name **resolved** — a cell, a range, a formula | the evaluator |
| `DefinedNameRecord` | the name **as the file wrote it** — text and attributes | the writer |

The reader produces both. The evaluator never sees the second; the writer never consults the
first, except for names created in code, which have no file text to preserve.

**This is the whole design**, and the argument for it is that reconstruction is lossy in a way
that is invisible until it matters:

```
file says:   'ANSWER KEY'!$M$1
target:      .sheetCell(SheetReference(sheet: "ANSWER KEY", cell: M1))
```

Writing that target back out means re-deciding the quoting rule, the `$` markers, and the
sheet-name escaping — a second serializer for a syntax the reader already read. And for the
shape the reader **cannot** parse at all, there is nothing to reconstruct from:

```
amounts = Expenditures!$D:$D    →    .formula(.text("Expenditures!$D:$D"))
```

The irony is instructive: **the names this package understands least are the ones it could
round-trip most safely today**, because the fallback keeps the text. The parsed ones are the
lossy ones.

---

## 4. API Surface

```swift
/// A `<definedName>` exactly as the file wrote it.
///
/// Held beside the resolved `NamedRange` rather than instead of it: the evaluator wants a
/// target it can read, and the writer wants the text the file used.
public struct DefinedNameRecord: Sendable, Equatable, Hashable {
    /// The name, as written.
    public let name: String
    /// The refers-to formula, verbatim.
    public let formula: String
    /// The sheet index for a sheet-scoped name, or `nil` for a workbook-scoped one.
    public let localSheetId: Int?
    /// Attributes the reader does not interpret, kept so the writer can put them back.
    public let attributes: [String: String]
}

extension Workbook {
    /// Every defined name, as the file wrote them.
    public var definedNameRecords: [DefinedNameRecord] { get }

    /// Adds a name to a workbook being built in code.
    ///
    /// The refers-to text is synthesised from the target, which is lossless because the
    /// target was just built rather than parsed.
    public func define(_ name: String, as target: NamedRangeTarget, scope: NameScope = .workbook)

    /// Adds a name whose refers-to text is supplied directly.
    ///
    /// For what this package cannot yet parse — a whole-column reference, a `LAMBDA`, a
    /// formula — so a caller is never blocked by the reader's limits.
    public func define(_ name: String, refersTo formula: String, scope: NameScope = .workbook)
}
```

---

## 5. MCP Schema

N/A. No new public entry point is exposed to a tool surface; `DefinedNameRecord` is a value
a caller may read, and it is already JSON-shaped if anyone needs it.

---

## 6. Constraints & Compliance

**Concurrency:** all four fields are `Sendable` value types.
**Safety:** no force unwraps; a record whose name is empty is dropped at read, as now.
**Fidelity:** unknown attributes are preserved as read rather than dropped or normalised.
**Determinism:** names are written in the order they were read, so a round trip is
byte-comparable in that element.

---

## 7. Source & API Compatibility

**Breaking changes: none.** Everything is additive — a new type, two new methods, one new
element in the output. No existing signature changes and no exhaustive switch gains a case.

**Incremental adoption:** automatic. A caller that reads and writes gets its names back
without changing a line.

**The risk is not source compatibility, it is output compatibility.** This writer has never
emitted this element, so every file it produces from now on contains something Excel has not
yet been asked to accept from it. §10 is mostly about that.

---

## 8. Backend Abstraction

N/A.

---

## 9. Dependencies

**Internal:** `NamedRange` and friends from SwiftExcelCore, unchanged.
**External:** none.

**Ordering within the batch:** first. The other four upstream defects are read-path and can
land in any order; this one changes what the writer produces and wants the longest soak.

---

## 10. Test Strategy

**Categories**

- **Round trip, by shape.** Read a workbook, write it, read it again, compare name tables.
- **Round trip, by corpus.** All 2,240 workbooks: read, write, read, and compare. The 1,182
  with names are the population that matters, and the comparison is exact.
- **Excel accepts it.** Write a file with every shape, open it in Excel, confirm no repair
  dialog and a Name Manager that agrees.
- **Built-ins.** `_xlnm.Print_Area` and `_xlnm.Print_Titles` survive with their
  `localSheetId`, because printing breaks silently if they do not.
- **Hidden names.** A name with `hidden="1"` comes back hidden.
- **Programmatic names.** A name added in code writes text Excel accepts.

**Reference truth:** the corpus, and Excel itself. The population is known — 1,022 workbooks,
161,901 names — so "the round trip is exact" is a claim with a denominator.

**Validation traces — from real files, with the text they must round-trip to:**

| From | Name | Refers to |
|---|---|---|
| `House Expenses 2.0.xlsx` | `amounts` | `Expenditures!$D:$D` |
| | `categoryFood` | `Definitions!$B$53` |
| | `lookupCategory` | `Definitions!$B$19:$C$51` |
| | `_xlnm._FilterDatabase` | `Expenditures!$A$2:$W$2446`, `localSheetId="1"`, `hidden="1"` |
| `lambda.xlsx` | `maxEXP` | `_xlfn.LAMBDA(_xlpm.arr,_xlpm.y,MAX(_xlpm.arr)^_xlpm.y)` |
| `2025 Reunions…xlsx` | `checkListDates25thAdjusted` | `'2018 - Sorted by Area'!$J$2:$J$333` |

The last is the one that would catch a reconstruction: a sheet name with spaces, quoted, with
absolute markers on both ends.

**The Excel check is not optional.** Writing a `<definedNames>` element in the wrong schema
position produces a file Excel repairs by deleting things, and this project has just spent
five rounds learning to recognise that — see `ExcelEvaluationLimits.md` §1. The repair log is
a precise instrument and it should be pointed at this deliberately.

---

## 11. Architecture Decision Review

**ADR check**

- [x] Reviewed `architecture_decisions.md`
- [x] Supersedes an existing ADR? **No**
- [x] Amends an existing ADR? **No**
- [x] New ADR required? **Yes** — "what a reader keeps" is a decision that will be asked again
      for styles, conditional formats, data validations and pivot caches, all of which the
      reader currently drops.

**New ADR draft**

- **Title:** A reader keeps what it cannot interpret
- **Category:** api
- **Key decision:** Where a file says something this package does not model, the *text* is
  preserved so a round trip returns it, rather than being dropped or reconstructed from a
  partial understanding.

---

## 12. Adversarial Review

**Strongest case for a different approach.**

Keep one representation, not two: reconstruct the refers-to text from `NamedRangeTarget` at
write time and store nothing extra. One source of truth, no duplicated state, no new type,
and a smaller diff.

The argument for it is not parsimony, it is **drift**. Two representations of the same fact
can disagree, and here they disagree silently in the worst possible direction: a caller
mutates a name's target, the record still holds the old text, and the writer puts **the old
reference** back into the file. The user's name now points somewhere else and nothing said
so. A single reconstructed source cannot do that.

That is a real hazard and the proposal must answer it rather than wave at it. The answer is
that `DefinedNameRecord` is `let`-only and the two are produced together at read; a mutation
path that can invalidate one without the other does not exist **today** — and §15 asks that
`define(_:as:)` be the only way to change a name, so it cannot exist tomorrow either. If that
discipline ever slips, this design is wrong and the reconstruction design is right.

**Where this design is most likely wrong.**

1. **"Preserve the text" is necessary and nowhere near sufficient — and the census says so.**
   `DefinedNameInfo` captures three fields, and `<definedName>` has a dozen attributes:
   `hidden`, `comment`, `description`, `customMenu`, `shortcutKey`, `function`, `vbProcedure`,
   `publishToServer`, `workbookParameter`.

   **74,992 of the corpus's 161,901 names are hidden — 46%.** A round trip that keeps the
   formula and drops `hidden="1"` does not lose a subtlety; it **empties half of every Name
   Manager into the user's face**, filter ranges and print-view scaffolding and all. On the
   Goldman model that is twenty thousand names appearing where none were visible before.

   I had assumed hidden names were a rarity worth a line of defensive code. They are half the
   population, and the `attributes` bag is the load-bearing part of this proposal rather than
   a tidiness measure. A version that shipped without it would be a worse outcome than the
   bug it fixes: today the names vanish silently, and that at least is uniform.
2. **Schema position is load-bearing.** `<definedNames>` sits after `<sheets>` and before
   `<calcPr>`. Emitting it in the wrong place yields a file Excel repairs, and the repair
   deletes rather than reorders.
3. **The corpus round trip may not be exact even when correct.** A file Excel wrote may
   contain names in an order or spelling this writer normalises; an exact comparison could
   fail for reasons that are not defects. The test should compare *name tables*, not bytes —
   and the temptation to compare bytes because it is easier should be resisted.
4. **This assumes the writer is worth fixing at all.** Nothing in this family writes workbooks
   as its main job today. If the answer is that callers should never round-trip a file
   through it, the honest fix is to make `save` refuse a workbook that was *read* rather than
   built — which would be a strange product but a defensible one.

**What an experienced critic would say.**

> "You are adding a parallel copy of state to a library, to fix a bug no user has reported,
> found by your own test harness — and the parallel copy is the classic way to create the
> next bug."

**Why we are proceeding anyway.** Because the bug is not hypothetical and the report would
never come: the loss is silent, the file opens, and the user discovers it later with no way to
connect it to us. 53% of the corpus is exposed. And the parallel-copy hazard is bounded by
making the record immutable and the mutation path singular — a discipline worth the check,
against a failure that is unbounded and undetectable.

---

## 13. Alternatives Considered

**Alternative 1 — reconstruct the text from the target at write time** (the counter-design)
- *Advantage:* one source of truth; no drift; no new type.
- *Disadvantage:* a second serializer for a syntax the reader already parsed; lossy for
  quoting and `$` markers; **impossible** for the shapes the reader cannot parse, which
  currently includes every whole-column name — those hold only `.formula(.text(…))` and would
  round-trip as a text constant, silently converting a range into a string.
- *Why not:* §12. It is right if and only if mutation can desynchronise the pair, and the
  design makes that unrepresentable.

**Alternative 2 — put the raw text on `NamedRange` in SwiftExcelCore**
- *Advantage:* one type, and the text travels with the name.
- *Disadvantage:* changes a public type in the shared core for something no consumer of that
  core needs; `NamedRange` is the *evaluator's* view, and the file's spelling is not part of
  it. Every consumer would gain a field that means nothing to them.
- *Why not:* the split exists to keep file-format concerns out of the vocabulary.

**Alternative 3 — keep the whole `workbook.xml` and patch it on save**
- *Advantage:* perfect fidelity for names *and* everything else the reader drops.
- *Disadvantage:* a different product — an editor rather than a reader and writer — and it
  makes every future change a text-surgery problem.
- *Why not:* far beyond this defect, though §14 notes it is where fidelity pressure points.

**Alternative 4 — do nothing, and document that the writer loses names**
- *Advantage:* free.
- *Disadvantage:* the documentation would be read by nobody who needed it, and the failure is
  silent. "We told you" is not a mitigation for data loss.
- *Why not:* stated so the file records that it was considered and rejected.

---

## 14. Future Directions

- **The same question, for everything else the reader drops.** Styles beyond the ones
  modelled, conditional formatting, data validations, charts, pivot caches. The ADR in §11 is
  written to be the precedent.
- **A fidelity report.** A tool that reads and writes a file and names what changed would turn
  "we probably preserved that" into a measurement — and the corpus would run it.
- **Names as a checker's subject.** A name pointing at a deleted range, a name shadowed by a
  sheet-scoped one, a name nothing references: all findings `stale-value`'s sibling could make
  once the name table survives a round trip.

---

## 15. Open Questions

- **Should `define(_:as:)` be the only mutation path?** §12's whole defence rests on the pair
  being immutable and produced together. If a caller can reach in and change a target, the
  record must be invalidated — and it would be better to make that unrepresentable.
- **What does the writer do with a name it never read and cannot synthesise?** A caller
  supplying refers-to text directly (`define(_:refersTo:)`) can write anything; validating it
  means parsing it, which is the thing that cannot parse whole columns.
- **Does the corpus contain a name this design loses?** The round trip over 2,240 workbooks
  answers it, and should run before the change is called done rather than after.

---

## 16. Documentation Strategy

**Documentation Type:** API docs, plus one paragraph in the reader's own DocC about what
survives a round trip — which is currently an unwritten and surprising list.

**Complexity Threshold Check:** combines 3+ APIs? No. 50+ lines to explain? No. Needs theory?
No.

---

**Next action:** the corpus census the proposal leans on — how many workbooks carry names, of
what shapes — so the round-trip test has a population before it has a fix.
