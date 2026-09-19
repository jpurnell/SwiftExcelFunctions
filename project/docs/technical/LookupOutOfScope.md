# The lookup functions this package does not implement

**What this is:** the reasons, one per function, for the `lookup` rows classified `out of
scope` rather than implemented. Written down because "out of scope" with no reason beside it
is indistinguishable from "not got to yet", and the two want different things from a reader.

Sixteen of the twenty-four were implemented — the dynamic-array family. These are the rest.

---

## They need something this package is not given

| Function | What it needs | Why that is not here |
|---|---|---|
| `RTD` | a running **real-time data server** | It asks a COM/RTD server for a value that changes on its own. There is no server, and a workbook audit whose answers changed between runs would not be an audit. |
| `IMAGE` | to **fetch a URL** | Returns an image from the web. This package makes no network calls, by design — a checker that reached out would give different answers on a different network. |
| `FIELDVALUE` | Excel's **linked data types** | Reads a field from a Stocks or Geography cell, whose contents come from a Microsoft service and are not in the file. |

Each of these is refused rather than approximated. A plausible answer here is worse than
none: the caller asked what the workbook computes, and the honest reply is that this cannot
be known from the file.

## They need the sheet, not the values

| Function | What it needs |
|---|---|
| `AREAS` | how many **ranges** a reference names — `AREAS((A1:B2,C3))` is 2 |
| `FORMULATEXT` | the **formula** in a cell, as text |
| `TRIMRANGE` | which cells in a range are **actually used** |

The evaluator is handed a `CellValueProvider`: a way to ask what a cell *holds*. These three
ask what a cell or a reference *is*, which is a different question and one the provider has
no way to answer. `AREAS` is the clearest case — its argument is a reference, not a value, and
by the time a function is called the reference has already become the values it names.

**This is the same boundary `ISREF` and `SUBTOTAL` already sit on**, and it is a boundary
worth keeping: the promise that `SwiftExcelFunctions` takes no dependency on a file format is
what lets the same evaluator serve a workbook reader, a solver and a test.

A consumer that *does* have the sheet can implement all three in a few lines by registering
them itself — the registry is open, and this is exactly what it is open for.

## ~~They are large, and nothing in the corpus asks for them~~ — implemented 2026-09-19

| Function | What it is |
|---|---|
| ~~`GROUPBY`~~ | aggregate rows by a key, with a lambda per aggregate, returning a shaped table |
| ~~`PIVOTBY`~~ | the same across two dimensions |

**Both are implemented.** The classification above said *"when one appears in a corpus, the
case changes and so should the classification"* — and then they were asked for directly,
which is the same thing arriving by a different route. Neither has appeared in a corpus and
the zero-demand measurement still stands; what changed is that demand was expressed.

The entry is struck through rather than deleted so the reasoning survives. It was right about
the obstacle: `LAMBDA` and the higher-order six did supply what was needed, and the work was
size rather than capability. It was also right that each carries its own options for totals,
sort order and header handling — and **those options are where the guessing is**. The
grouping and aggregation are not in doubt; the defaults are, so `ConformanceCases.roundTen`
asks Excel about them rather than leaving them as this package's opinion.

One implementation note worth keeping here. The aggregate arrives **eta-reduced** —
`GROUPBY(…, SUM)` names the function rather than calling it — and the parser reads a bare
name as a `.namedRange`. Evaluated first, `SUM` is a name the workbook does not define and
the call is `#NAME?` before it starts, so both are reached in the evaluator before their
arguments, the way `LAMBDA` is.

---

## What "out of scope" means here

Not "hard". Three of these need a service or a network, three need a layer this package
deliberately does not have, and two are simply larger than their measured demand. Each row in
the coverage matrix carries this file's reason, and a row whose reason stops being true should
move back.
