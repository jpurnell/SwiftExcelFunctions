# GETPIVOTDATA — a lookup into a rendered table, not a recomputation

**Status:** phase one shipped. 3,802 cells across four corpus workbooks, 77% of everything
a 300-workbook run still disagrees on; **228 of them now agree** and 3,574 remain.
**Written:** 2026-09-20, from evidence in `Amazon Reporting thru 05-15-18.xlsx`.
**Revised:** 2026-09-20, after measuring the phase split properly — see below.

---

## The insight this document exists to preserve

**`GETPIVOTDATA` does not need `xl/pivotCache/`.** It does not aggregate anything. A pivot
table's values are already **rendered onto the worksheet and cached there** like any other
cell, and `GETPIVOTDATA` reads one of them.

That was not obvious, and the obvious reading is expensive: parse the cache definitions and
records, model fields and items, reimplement Excel's aggregation, and reconcile the result
with whatever the workbook's author last refreshed. One corpus file carries **76 cache parts**.
None of that is needed.

> **Narrowed by measurement, later.** This holds exactly for the two-argument form that
> shipped. Field/item pairs do need the cache **definitions** — field identity in a pivot
> table definition is positional, and only `pivotCacheDefinition*.xml` carries the names. The
> **records** are still never read and nothing is ever recomputed. See *Phase two, measured*.

The evidence, end to end, for

```
GETPIVOTDATA("Sum of # Minutes Streamed", 'W-E Nov 18'!$M$1)
```

which Excel answers `24933649.49000001`:

```xml
<!-- xl/pivotTables/pivotTable24.xml -->
<location ref="M1:O253" firstHeaderRow="0" firstDataRow="1" firstDataCol="1"/>
<dataField name="Sum of # Streams"          fld="8" baseField="0" baseItem="0"/>
<dataField name="Sum of # Minutes Streamed" fld="9" baseField="0" baseItem="0"/>
```

```
sheet38.xml   M1   "Row Labels"    N1   "Sum of # Streams"   O1  "Sum of # Minutes Streamed"
              M253 "Grand Total"   N253 763494               O253 24933649.49000001
```

`O253` is byte-identical to the value Excel cached for the formula. The whole resolution is:
anchor cell → the pivot whose `ref` contains it → data field name → its column → grand total
row → read the cell.

## What the function actually does

```
GETPIVOTDATA(data_field, pivot_table, [field1, item1], [field2, item2], …)
```

- **`pivot_table`** is *any cell inside a pivot table's range*, and it exists only to identify
  which pivot is meant. In the corpus it is always the anchor, `$M$1`.
- **`data_field`** names a `<dataField>`, which is also the text written into that field's
  column header on the sheet.
- **field/item pairs** narrow to a row. With none, the answer is the grand total.

## The three pieces of work

### 1. Read the pivot definitions — SwiftXLSX

Per pivot table, only:

| Wanted | Where |
|---|---|
| location `ref` | `<location ref="M1:O253"/>` |
| `firstDataRow`, `firstDataCol` | same element |
| data field names, **in order** | `<dataField name="…"/>` |
| owning sheet | `xl/worksheets/_rels/sheetN.xml.rels` → `../pivotTables/pivotTableN.xml` |
| whether grand totals exist | `rowGrandTotals` / `colGrandTotals`, **default on** |

Everything else in a 5 KB part is ignored, and `xl/pivotCache/` is never opened. In the file
examined that is 38 pivot parts read instead of 114 parts read and modelled.

### 2. Expose it — the additive shape, twice proven

`CellValueProvider` gained `sheetNames()` for 3-D references with a default returning none, so
every existing conformance kept compiling and behaving identically. The same shape applies:

```swift
/// The pivot tables this workbook renders, for GETPIVOTDATA.
/// A default returns none — a provider that does not model a workbook has no pivots to give,
/// and GETPIVOTDATA over it is #REF!, which is what it answers today.
func pivotTables() -> [PivotTableLayout]
```

`PivotTableLayout` belongs in SwiftExcelCore beside `SheetReference`: sheet name, range,
first data row and column, and the ordered data field names. It carries **no values** — the
values are read through the provider from the sheet, which is the entire point.

### 3. Implement the function — SwiftExcelFunctions

Resolve in this order, refusing rather than guessing at each step:

1. Evaluate argument 2 to a reference; find the pivot whose range contains it. None → `#REF!`.
2. Match `data_field` against the layout's names. No match → `#REF!`.
3. Find that field's **column**: the header row of the range, matched by text.
4. Find the **row**: grand total when there are no pairs, otherwise the row whose labels match
   every field/item pair.
5. Read that cell through the provider.

## Phasing, and the split — corrected after measuring it

**The split first recorded here was wrong, and the error was in the measurement, not the
plan.** It read:

> **Phase one — 1,800 cells.** The two-argument grand-total form.
> **Phase two — 2,002 cells.** Field/item pairs.

Those numbers came from classifying formulas with the regex
`GETPIVOTDATA\([^,]*,[^,)]*\)` — "an open paren, something with no comma, a comma, something
with no comma, a close paren". It counts a call's arguments by counting commas, and it breaks
the moment the **first argument is itself a call**, which in this corpus it usually is:

```
IFERROR(GETPIVOTDATA(TEXT($B87,""),$C$267,"Region",$D87, … ),0)
                                ^ this comma ended the match
```

`TEXT($B87,"")` contains a comma, so the regex stopped there and read a **five-pair call as a
two-argument one**. Every such cell was counted into phase one.

### What the corpus actually contains

Counted by parsing — tracking paren depth and string literals rather than matching commas —
across all 3,574 `GETPIVOTDATA` findings that survive phase one:

| arguments | field/item pairs | cells |
|---:|---:|---:|
| 8 | 3 | 1,612 |
| 10 | 4 | 1,758 |
| 12 | 5 | 204 |
| **2** | **0** | **0** |

**Not one two-argument call is left.** The two-argument population was 228 cells, every one of
them in the three Amazon workbooks, and phase one cleared all of them: those three files now
agree with Excel on every comparable cell.

| | cells | where |
|---|---:|---|
| phase one — two-argument grand total | 228 | three Amazon workbooks, **all now agreeing** |
| phase two — field/item pairs | 3,574 | all in `Dot Com YTD Performance Report 6 20.xlsx` |

So phase one was a quarter the size it was sold as, and phase two is the whole remainder.

### Why the correction is worth as much as the fix

The regex agreed with the plan. It was written to confirm a split that had already been
described in prose, it produced a number close enough to "almost evenly" to look right, and
nothing downstream would ever have contradicted it — phase two's work is the same work whether
it is 2,002 cells or 3,574.

What caught it was reading the tool's own output rather than its summary line: a row printed
under the heading `two-argument forms still failing` had `"Region",$D87` plainly visible in it.
A classifier that disagrees with the text it just printed is wrong about the text, not about
the printing.

The rule this earns: **a population count is a measurement and gets the same scrutiny as a
result.** Parse when the grammar is nested; a regex over formula text is a heuristic, and a
heuristic that happens to confirm the plan is the one least likely to be checked.

### Phase two, sized honestly

```
GETPIVOTDATA("Subs", $BA$393, "Region", $R$196, "FME_Calc", U$181, "Scenario", "CY")
```

Three to five pairs, most read from *other cells* rather than written as literals. This needs
the row labels matched against item values, and in a multi-field pivot the labels are laid out
hierarchically rather than one per column — and subtotal rows (`"KEY Total"`, `"WNE Total"`)
have to be told apart from data rows, which the two-argument form never had to do. Harder,
still a lookup, still no aggregation.

It is also **one workbook**. 3,574 cells is a large number attached to a single file, and a
capability built to satisfy one file needs its round of independent evidence before it is
believed — the same bar every other fix here was held to.

## Phase two, measured — and two things above are wrong

The 50 pivots in `Dot Com YTD Performance Report 6 20.xlsx` were read rather than assumed.
`pivotTable2.xml`, at `BA393:BJ502`, is the one the formulas hit hardest:

```
<location ref="BA393:BJ502" firstHeaderRow="1" firstDataRow="2" firstDataCol="4"
          rowPageCount="2" colPageCount="1"/>
<rowFields count="4"><field x="4"/><field x="0"/><field x="7"/><field x="16"/></rowFields>
<colFields count="1"><field x="1"/></colFields>
<pageFields count="2"><pageField fld="9"/><pageField fld="6" item="0"/></pageFields>
<dataFields count="1"><dataField name="Sum of Subs" fld="11"/></dataFields>
```

and the corpus formula against it is

```
GETPIVOTDATA("Subs", $BA$393, "Region", $R$216, "FME_Calc", X$181,
             "Scenario", "CY", "LOBMix_noXH", "D")
```

### Correction 1 — a pair is not necessarily a row field

`Region`, `Scenario` and `LOBMix_noXH` are row fields; **`FME_Calc` is a column field.** This
document said throughout that pairs are matched against *row labels*. They are matched against
whichever axis the field sits on, and a page (filter) field is a third case again — a pair
naming one must agree with the filter's current selection or the answer is `#REF!`.

Across the 50 pivots: **40 carry page fields, 38 carry column fields, 39 carry more than one
row field.** The single-row-field pivot the phase-one fixture models is the minority shape
here, not the normal one.

### Correction 2 — `xl/pivotCache/` is not optional for phase two

The headline of this document — *`GETPIVOTDATA` does not need the pivot cache* — holds for the
two-argument form and does not survive field/item pairs. **Field identity in a pivot table
definition is positional.** `<field x="4"/>` and `fld="11"` are indices, and nothing in
`pivotTables/` says index 4 is `Scenario` or index 11 is `Subs`. Only
`xl/pivotCache/pivotCacheDefinition*.xml` carries `<cacheField name="…"/>`.

The distinction that matters is **definitions versus records**:

| part | size here | needed |
|---|---:|---|
| `pivotCacheDefinition*.xml` | 7 parts, 0.8–12 KB | **yes** — the field names, and nothing else |
| `pivotCacheRecords*.xml` | 2 parts, 32 KB | no — still never read, still never aggregated |

So the insight is narrower than first written, not wrong: the *records* are never read and
nothing is ever recomputed. One corpus workbook's 76 cache parts remain unopened for phase
one; phase two opens the definitions of them and reads names out.

### Correction 3 — the data field is matched by source name, not only by caption

The formula asks for `"Subs"`. The sheet caption is `"Sum of Subs"` and the definition reads
`<dataField name="Sum of Subs" fld="11"/>`, where field 11 is the cache field named `Subs`.
Excel accepts either. **Phase one matches captions only** — `layout.dataFields.contains(field)`
— which worked on the Amazon fixture because that formula spells out the full caption, and
would refuse every one of these. It is not a bug in what shipped, but it is a gap that phase
two closes with the cache definition it is already reading.

The caption list in this workbook also contains `" B1"`, `" CDV"`, `" HSI"` — **leading
spaces**, written by whoever built it. Whatever matches names has to be exact, because
trimming would make three captions collide with nothing and a "helpful" trim is how a lookup
starts answering the wrong column.

### The rendering, which is where the real work is

`BA391:BB391` — the page fields, above the table.
`BA393` — the data field caption.
`BA394:BD394` — the row field **names**, one per row-label column.
`BE393` — the column field name; `BE394:…` its items.
`BA395` down — the data.

```
        BA            BB       BC             BD       BE    BF    BG
 391  ActivityDetail  119                                                ← page field
 393  Sum of Subs                             FME_Calc                   ← captions
 394  Scenario        Region   LOBMix_noXH    BP/IP     20    21    22    ← names / col items
 395  42              3        103                      303   301   256
 396                           105                      1633  1233  944
 397                           115                      44    34    29
 398                           107            140       487   319   390
 399                                          141       183   218   238
```

**The row labels are sparse.** `BA395` reads `42` and `BA396:BA399` are empty: an outline
rendering writes a label once and the rows beneath inherit it. A lookup that scans the column
for a matching item finds one row in five. Matching a pair means carrying the last non-blank
value down each row-label column first, then intersecting the four columns' constraints.

Two further traps visible in those seven rows: the items are **numbers rendered as numbers**
(`42`, `3`, `103`), so item comparison is value equality and not string equality; and the row
field names sit in the same column as the labels, one row above the data, so an off-by-one
reads `Scenario` as an item.

### What this makes phase two

1. Parse `pivotCacheDefinition*.xml` for `<cacheField name>`, following the pivot table's own
   relationship to find the right one. Definitions only.
2. Carry the row/col/page field **indices** on the layout, resolved to names.
3. Resolve each formula pair to its field, then to its axis.
4. Row-axis pairs: fill down the label columns, intersect. Column-axis pairs: match the header
   items. Page-axis pairs: compare against the rendered selection; disagree and it is `#REF!`.
5. Subtotal rows (`"KEY Total"`, `"WNE Total"`) are not data rows and must be skipped.

It is three repositories again — `PivotTableLayout` grows, the parser grows, the function
grows — and it is **one workbook**. 3,574 cells behind a single file is a large number with a
narrow base, and a capability built to satisfy one file needs independent evidence before it
is believed, exactly as every other fix here did.

## What must be measured before writing it

**Where the grand total row is.** It was found above by the label `"Grand Total"` in the
row-label column. That works perfectly on this corpus and **would fail on the first German
workbook**, where the label is `"Gesamtergebnis"`. The structural alternative is the last row
of `location ref` when `rowGrandTotals` is on.

Those two agree here, which is exactly the condition under which a wrong rule survives. A
round should ask:

- a pivot with `rowGrandTotals="0"` — is the last row then an ordinary row?
- a pivot with a column grand total but no row grand total
- a pivot whose row labels contain the literal text `"Grand Total"` as data
- `GETPIVOTDATA` against a cell *inside* the pivot but not its anchor
- `GETPIVOTDATA` naming a data field that is not in the pivot — `#REF!`, presumably
- the same, against a cell in no pivot at all

That round needs a workbook **containing a pivot table**, which the conformance emitter cannot
write today — it writes formulas and values, not pivot parts. So either the round is built by
hand from a workbook with pivots in it, or the emitter learns to carry one. That is a real
prerequisite and not a footnote.

### The corpus answered it, and the prerequisite is gone

**`Dot Com YTD Performance Report 6 20.xlsx` contains both cases**, which makes it the natural
experiment this section was asking for:

| pivots | `rowGrandTotals` | `colGrandTotals` |
|---:|---|---|
| 10 | `0` | `0` |
| 3 | `0` | default |
| 36 | default | `0` |
| 1 | default | default |

Reading the last row of each declared `location ref`:

| | last row |
|---|---|
| `rowGrandTotals="0"`, `AD130:AL176` | `AD175` is `"KEY Total"` — a **subtotal**; `AD176` is empty |
| `rowGrandTotals` defaulted, `BA286:BJ383` | `BA383` is **`"Grand Total"`** |

**The structural rule holds.** When row grand totals are on, the grand total is the last row of
the location; when they are off, there is none — and the last populated row is an ordinary
subtotal that a label match would have mistaken for one, since `"KEY Total"` ends in the same
word.

So the grand total is found by `location ref` and `rowGrandTotals`, never by matching
`"Grand Total"`, and **no hand-built round is needed**. The locale trap is avoided by not
reading labels at all.

One thing this turned up for phase two: `"KEY Total"` and `"WNE Total"` are **subtotal** rows,
so these pivots carry more than one row field. Matching field/item pairs will have to
distinguish a subtotal row from a data row, which the two-argument form never has to.

## Why this is a capability and not a defect

The same shape as 3-D references: the corpus says *that* these cells need it, and only the
file format says *how*. No conformance round can settle it, because there is nothing to
compare — this package does not refuse `GETPIVOTDATA` because it computes it wrongly, but
because it has never read a pivot definition.

`GETPIVOTDATA` answers `#REF!` where it cannot answer, which is honest, and 1,040 of the
remaining findings are recorded as `refused` rather than `differed` for that reason. The other
2,534 are `differed` because the refusal happens inside an `IFERROR` or a `TEXT` that then
produces a value — which is also why a phase-two failure will read as `ours=[0.0]` rather than
as an error, and why the raw outcome column cannot be trusted to say what failed.

## Risks worth naming now

- **The label-matching shortcut.** Described above. It is the single most likely way to ship
  something that passes every test here and fails elsewhere.
- **Multiple pivots on one sheet.** The lookup is by containment, so overlapping or adjacent
  pivots need the smallest containing range, not the first match.
- **A stale rendering.** The values on the sheet are whatever the author last refreshed. That
  is the same contract the rest of the oracle already works under — `StaleValueChecker` exists
  for exactly this — and is not a reason to aggregate instead. Aggregating would *disagree*
  with a workbook whose pivot was never refreshed, which is the wrong answer to give about a
  file.
- **`firstDataRow` is relative to the location**, not to the sheet. Off-by-one here reads a
  header as a value and looks plausible.
