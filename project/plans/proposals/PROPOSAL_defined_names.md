# Design Proposal: A workbook keeps its defined names

**Date:** 2026-09-16
**Status:** **Approved 2026-09-16** — single representation, per §12
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

**One representation. There is no second copy of anything.**

A name is a `NamedRange`, the writer derives its refers-to text from that `NamedRange`, and
nothing else holds a competing version of the same fact. Two representations that can
disagree are a defect waiting for someone to mutate one of them, and the only thing this tool
has is that its answers can be trusted.

**Modified (SwiftExcelCore)**

- `NamedRangeTarget` gains **`.unparsed(String)`** — see §3.1. Breaking; §7.
- `NamedRange` gains the attributes a round trip needs: `isHidden`, and a bag for the rest.

**Modified (SwiftXLSX)**

- `Reader/DefinedNameResolver.swift` — `isReference` accepts a whole column and a whole row.
- `Reader/WorkbookXMLParser.swift` — `DefinedNameInfo` carries every attribute.
- `Workbook.swift` — a public way to add a name; the writer emits `<definedNames>`.
- `Writer` — a `NamedRangeTarget` → text serializer, which is the load-bearing new code.

### 3.1 Making the target honest, which is what the single representation requires

Reconstructing text from the target is only safe if the target can *say* everything a name
can be. Today it cannot, and the gap is not cosmetic:

```
amounts = Expenditures!$D:$D   →   .formula(.text("Expenditures!$D:$D"))
```

That is a **lie about the kind of thing the name is.** It claims a text constant.
Serializing it back gives a quoted string, so the name stops being a range — and the
naive form of this design would corrupt **3,886 names in the corpus** on its first run.
Worse, the same lie is live in the evaluator today: `SUMIFS(amounts, …)` sums nothing,
because `amounts` evaluates to its own text. It is upstream defect #1 and this is upstream
defect #5, and **they are the same bug seen from two ends.**

So the target learns to say three true things instead of two:

| Target | Means | Round-trips by |
|---|---|---|
| `.cell`, `.range`, `.sheetCell`, `.sheetRange` | a reference this package understands | serializing the reference — exact, because `CellRef` keeps its `$` markers |
| `.formula(FormulaAST)` | a formula this package parsed | `FormulaSerializer` |
| **`.unparsed(String)`** | **a refers-to this package could not read** | the identity function |

`.unparsed` is not a parallel copy. It *is* the target — the honest statement that the
reader did not understand this one — and writing it back is the identity. A name in that
state cannot drift from itself.

**Fixing `isReference` is most of the win.** It currently requires a letter *and* a digit in
each half, so `$D` fails and every whole-column name falls through. With whole columns and
whole rows parsing properly, `.unparsed` is left holding only what it should: genuine
oddities, which the corpus round trip will enumerate rather than leave to guesswork.

## 4. API Surface

```swift
// SwiftExcelCore
public enum NamedRangeTarget: Sendable, Equatable, Hashable {
    case cell(CellRef)
    case range(CellRange)
    case sheetCell(SheetReference)
    case sheetRange(SheetReference)
    case formula(FormulaAST)
    /// A refers-to this package could not read, kept exactly as the file wrote it.
    ///
    /// Distinct from `.formula(.text(…))`, which claims the name *is* a text constant —
    /// a claim that is false for every whole-column name and costs 3,886 of them.
    case unparsed(String)
}

public struct NamedRange: Sendable, Equatable, Hashable {
    public let name: String
    public let reference: NamedRangeTarget
    public let scope: NameScope
    /// Hidden names are 46% of the corpus. Dropping this un-hides half of every Name Manager.
    public let isHidden: Bool
    /// Attributes this package does not interpret, kept so a round trip returns them.
    public let attributes: [String: String]
}
```

```swift
// SwiftXLSX
extension Workbook {
    /// Adds a name. The refers-to text is derived from the target when the file is written,
    /// so there is nothing to keep in step.
    public func define(_ name: String, as target: NamedRangeTarget,
                       scope: NameScope = .workbook, hidden: Bool = false)
}
```

**There is no `refersTo:` overload and no record type.** A caller who needs to write something
this package cannot parse passes `.unparsed("…")` and says so in the type, rather than
handing the writer a string that shadows a target.

## 5. MCP Schema

N/A. No new public entry point is exposed to a tool surface; `DefinedNameRecord` is a value
a caller may read, and it is already JSON-shaped if anyone needs it.

---

## 6. Constraints & Compliance

**Concurrency:** every field is a `Sendable` value type.
**Safety:** no force unwraps; a name with an empty name is dropped at read, as now.
**Fidelity:** attributes preserved as read; `.unparsed` returns its text unchanged.
**Determinism:** names written in read order, so a round trip is stable.
**No drift, by construction:** one fact, one place. The written text is a *function of* the
target rather than a copy kept beside it, so there is no state to fall out of step.

## 7. Source & API Compatibility

**Breaking: yes, and deliberately.** `NamedRangeTarget` gains a case, so every exhaustive
switch over it stops compiling — in SwiftXLSX, in this package, and in anything else built on
SwiftExcelCore.

That is the price of the single representation, and it buys more than it costs. The
alternative kept the enum intact by leaving `.formula(.text(…))` in place — an entry that
lies about what a name is, and that is *already* producing wrong answers in the evaluator
(§3.1). A case that forces every consumer to decide what to do with "I could not read this"
is better than one that quietly hands them a text constant.

**It lands with the release that already breaks.** `CellValue.lambda` and `ExcelError.calc`
are both queued for the same SwiftExcelCore minor version. One break, one migration, three
things fixed.

**Incremental adoption:** a caller that reads and writes gets its names back without changing
a line, once recompiled.

**The risk that is not source compatibility:** this writer has never emitted `<definedNames>`,
so every file it produces from now on contains something Excel has not yet been asked to
accept from it. §10 is mostly about that.

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

**This test carries more weight than it did.** With a parallel record it would have checked
that bytes were copied; with reconstruction it checks that every quoting rule, every `$`
marker and every sheet-name escape is right across 161,901 names. It is the measurement that
justifies choosing reconstruction over copying (§12), so it runs before the change is called
done, not after.

**And it reports one number that is not a pass/fail:** how many names land in `.unparsed`.
That is the reader's health, it should fall to near zero once whole columns and rows parse,
and a rising count means the reader is regressing behind a safety net.

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

- **Title:** One fact, one representation — and a reader says when it could not read
- **Category:** api
- **Key decision:** A value this package reads is held exactly once. Where a file says
  something the package cannot model, the model gains a case that *says so* — carrying the
  original text — rather than a parallel copy kept beside a lossy interpretation. Two
  representations of one fact can disagree, and a library whose correctness depends on a
  discipline no compiler enforces is correct only until someone forgets.

---

## 12. Adversarial Review

> **This section changed the design.** The first draft proposed a `DefinedNameRecord` holding
> the file's text beside the resolved `NamedRange` — two representations of one fact. The
> review below argued against it, and the argument won: *the only thing this tool has is that
> its answers can be trusted, and anything that can drift is not worth having.* What follows
> now argues against the design that replaced it.

**Strongest case for a different approach.**

Keep the parallel record after all. Copying the file's bytes and writing them back is
*trivially* correct for all 161,901 names: no quoting rule to get right, no `$` marker to
preserve, no sheet-name escape to reason about. The chosen design replaces a copying problem
with a **reconstruction** problem, and reconstruction has to be right every single time.

That is a real trade and it should be named plainly: **we have exchanged a drift risk for a
correctness-of-reconstruction risk.**

The reason to take it is that the two risks are not the same shape. Reconstruction is
**measurable** — 1,022 workbooks, 161,901 names, read-write-read, and any name that comes back
different is a defect with an address. Drift is a future mutation nobody has written yet; no
test can enumerate it, and it would be found by a user whose file was already wrong. This
project's whole method is to prefer the risk that can be measured over the one that has to be
promised, and §10 is that measurement.

**Where this design is most likely wrong.**

1. **Reconstruction is exact only if every rule is.** `$` markers survive because `CellRef`
   carries `absoluteColumn` and `absoluteRow`. Sheet-name quoting — `'2018 - Sorted by Area'`
   — is a rule this package must now *own*, and Excel's rule is "quote unless the name is
   letters, digits and underscores, starting with a letter." Get that wrong and names break
   in exactly the files most likely to have spaces in sheet names, which is most of them.
2. **`FormulaSerializer` is not byte-exact.** `_xlfn.LAMBDA(…)` comes back `_XLFN.LAMBDA(…)`.
   Excel accepts either, but a round trip that is only *semantically* exact cannot be
   verified by comparing strings, and the test must therefore compare *parsed* targets. That
   is a weaker test than byte equality and it is the one available.
3. **`.unparsed` could become a dumping ground.** Every shape the reader fails on lands there
   and round-trips safely, which is the point — and also removes the pressure to parse it
   properly. The corpus count of `.unparsed` names is the number to watch; it should fall to
   near zero once whole columns and rows parse, and a rising count means the reader is
   regressing behind a safety net.
4. **The breaking change may not be worth it on its own.** If `CellValue.lambda` were not
   already queued, forcing every consumer to recompile for this would be a harder argument.
   It rides along; if the `LAMBDA` work were shelved, this should be reconsidered rather than
   shipped alone.

**What an experienced critic would say.**

> "You have turned a copy into a computation, and computations have bugs that copies do not.
> You now have to be right about Excel's quoting rules for a hundred and sixty thousand names
> you have never looked at."

**Why we are proceeding anyway.** Because being right about those rules is *checkable*, and
because the copy was only correct as long as nobody touched it. A tool whose correctness
depends on a discipline no compiler enforces is a tool that is correct until it is quietly
not — and there is no version of this library worth shipping that cannot be trusted about
what a name points at.

## 13. Alternatives Considered

**Alternative 1 — a `DefinedNameRecord` beside the `NamedRange`** *(the first draft)*
- *Advantage:* trivially correct round trip; no reconstruction rules to own; non-breaking.
- *Disadvantage:* two representations of one fact, which can disagree the moment anything
  mutates a target — and disagree *silently*, writing the old reference back into the user's
  file.
- *Why rejected:* §12. A correctness that depends on an unenforced discipline is not a
  correctness this tool can offer.

**Alternative 2 — reconstruct from the target as it stands today, no new case**
- *Advantage:* single representation with no breaking change at all.
- *Disadvantage:* **corrupts 3,886 names on the first run.** A whole-column name is currently
  `.formula(.text("Expenditures!$D:$D"))`, and serializing a text node produces a quoted
  string — so the name stops being a range and becomes a caption.
- *Why rejected:* it is the chosen design minus the one thing that makes it safe.

**Alternative 3 — keep the whole `workbook.xml` and patch it on save**
- *Advantage:* perfect fidelity for names *and* everything else the reader drops.
- *Disadvantage:* a different product — an editor rather than a reader and writer — and every
  future change becomes text surgery.
- *Why rejected:* far beyond this defect, though §14 notes where the pressure points.

**Alternative 4 — do nothing; document the loss**
- *Advantage:* free.
- *Disadvantage:* the documentation would be read by nobody who needed it, and the failure is
  silent. "We told you" is not a mitigation for data loss.
- *Why rejected:* recorded so the file shows it was considered.

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

- **What is Excel's exact sheet-name quoting rule?** The working rule is "quote unless the
  name is letters, digits and underscores and does not begin with a digit", and it should be
  *measured* against the corpus rather than assumed — 161,901 names is a large enough sample
  to find the exception if there is one.
- **How many names land in `.unparsed` once whole columns and rows parse?** The count is the
  health metric for the reader, and it should be part of the round-trip report rather than a
  thing someone remembers to check.
- **Does `FormulaSerializer`'s uppercasing matter to Excel?** `_XLFN.LAMBDA` is accepted, but
  the round trip is then not byte-stable, and a future fidelity report would flag it. Worth
  knowing whether the serializer should preserve the case it read.

## 16. Documentation Strategy

**Documentation Type:** API docs, plus one paragraph in the reader's own DocC about what
survives a round trip — which is currently an unwritten and surprising list.

**Complexity Threshold Check:** combines 3+ APIs? No. 50+ lines to explain? No. Needs theory?
No.

---

**Next action:** the corpus census the proposal leans on — how many workbooks carry names, of
what shapes — so the round-trip test has a population before it has a fix.
