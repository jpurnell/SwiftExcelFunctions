# The eight lookup functions this package does not implement

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

## They are large, and nothing in the corpus asks for them

| Function | What it is |
|---|---|
| `GROUPBY` | aggregate rows by a key, with a lambda per aggregate, returning a shaped table |
| `PIVOTBY` | the same across two dimensions |

These are implementable. `LAMBDA` and the higher-order six landed in this session and supply
what they need, so the obstacle is size rather than capability — each is a small feature in
its own right, with its own options for totals, sort order and header handling.

They are classified out of scope on evidence rather than taste: **zero calls across 2,240
workbooks**, alongside every other function in this bucket. When one appears in a corpus, the
case changes and so should the classification.

---

## What "out of scope" means here

Not "hard". Three of these need a service or a network, three need a layer this package
deliberately does not have, and two are simply larger than their measured demand. Each row in
the coverage matrix carries this file's reason, and a row whose reason stops being true should
move back.
