# Design Proposal: `LAMBDA`, and what it asks of an evaluator

**Date:** 2026-09-15
**Status:** Proposed
**Category:** evaluation semantics

---

## 1. Objective

Decide whether this package implements `LAMBDA` and the seven functions that take one, and
if so, what has to change to make room for it.

The honest version of the question is narrower than it looks. `LAMBDA` does not need Swift
closures, a type system, or anything a spreadsheet does not already have. It needs **two
things this evaluator does not have**: a value that can be a function, and a place to put
local names. Everything else in the family follows from those two.

---

## 2. What the corpus actually holds

**Measured, because the first measurement was wrong.** A scan for the string `LAMBDA`
across 2,240 workbooks returns **134 hits and 2 real uses**: every modern Excel writes

```xml
<xcalcf:feature name="microsoft.com:LAMBDA_WF"/>
```

into `<extLst>` whether or not the file uses the feature. Scanning for `_xlfn.LAMBDA` — the
spelling a stored formula actually uses — gives the true count.

| Measure | Found |
|---|---|
| Workbooks defining a `LAMBDA` | **2** of 2,240 |
| Workbooks using `LET` | **0** |
| Calls to a defined `LAMBDA` | **10,802** |
| Distinct `LAMBDA`s defined | 4 |

### 2.1 The correction that matters

`RANDOMNORMAL` is **the most-called function name this package cannot answer** — 10,801
calls, more than fifty times the next name on the list. The first census wrote it up as
Crystal Ball's, on the strength of the name and of `CB.RECALCCOUNTERFN` appearing in the
same sweep. It is not. It is a `LAMBDA` defined in the workbook:

```
randomNormal = _xlfn.LAMBDA(_xlpm.x, _xlpm.y,
                 _xlpm.x + _xlpm.y * SQRT(-2*LOG(RAND())) * COS(2*PI()*RAND()))
```

A Box–Muller normal draw, written by whoever built the model, called once per cell across a
10,800-cell simulation grid. `MYLAMBDA` and `MAXEXP` are the same story at a smaller scale.

So the reading that followed from the first census — *"the `LAMBDA` family has no measured
demand"* — was wrong, and wrong in the direction that matters: **one `LAMBDA` accounts for
more unanswerable calls than every other missing function in the corpus put together.**

Two workbooks is still two workbooks. What the correction changes is the *reason* to
schedule this: not "nobody uses it" but "almost nobody uses it, and the one who does uses it
ten thousand times".

### 2.2 The three shapes, as stored

```
① named            maxEXP = _xlfn.LAMBDA(_xlpm.arr, _xlpm.y, MAX(_xlpm.arr)^_xlpm.y)
② called by name   =myLambda(D2)                                   → 5
③ called in place  =_xlfn.LAMBDA(_xlpm.x,_xlpm.y, …)(F8,F9)        → 0.361457…
```

Two prefixes carry the whole file-format story:

- **`_xlfn.`** on the function, which this package already strips — `FunctionRegistry.canonical`
  handles `_xlfn.` and `_xll.` and has since the beginning.
- **`_xlpm.`** on every parameter, in the declaration *and* in the body. That is Excel saying
  "this identifier is a parameter, not a defined name". It is a **gift**: the binder does not
  have to infer scope from position, because the file already marks it.

---

## 3. What the parser already does

Put to `FormulaParser` as written:

| Form | Result |
|---|---|
| `_xlfn.LAMBDA(_xlpm.x, _xlpm.x+1)` | ✅ `function("_XLFN.LAMBDA", [namedRange("_xlpm.x"), add(…)])` |
| `myLambda(D2)` | ✅ `function("MYLAMBDA", [cellRef(D2)])` |
| `_xlfn.LET(_xlpm.a, 2, _xlpm.a*3)` | ✅ `function("_XLFN.LET", …)` |
| `MAP(A1:A3, _xlfn.LAMBDA(_xlpm.v, _xlpm.v*2))` | ✅ nested function node |
| `ISOMITTED(_xlpm.y)` | ✅ |
| `LAMBDA(…)(F8,F9)` | ❌ `unexpectedToken(expected: "end of expression", found: "(")` |

**Five of six parse already**, because `LAMBDA` is syntactically an ordinary function call and
its parameters are syntactically ordinary names. Only shape ③ — a call applied to a
parenthesised expression — is a grammar this parser does not have, and it is upstream in
SwiftXLSX.

That is the single most useful fact in this document: **the representation problem is mostly
already solved.** What is missing is evaluation, not syntax.

---

## 4. What is actually missing

### 4.1 A value that can be a function

```swift
public enum CellValue {
    case number(Double), text(String), bool(Bool), error(ExcelError)
    case blank, date(Date), array(CellMatrix), formula(FormulaAST, cached: CellValue?)
}
```

`MAP(A1:A3, LAMBDA(v, v*2))` passes a function *as an argument*, and there is no case for
one. This is the change with real cost, because `CellValue` is public in SwiftExcelCore and
a new case breaks every exhaustive switch over it — in this package, in SwiftXLSX, and in
anything else built on it.

**It does not need a Swift closure.** A `LAMBDA` is its own syntax: a parameter list and a
body, both of which are already `Equatable`, `Hashable` and `Sendable` because `FormulaAST`
is. A closure would be none of those and would have made `CellValue` unhashable overnight.

```swift
case lambda(parameters: [String], body: FormulaAST)
```

That is the whole of it. The apparent incompatibility with Swift is not one: it comes from
imagining a lambda as a *function*, where Swift's answer is a non-Equatable, non-Sendable
closure. Held as *syntax*, every protocol `CellValue` conforms to keeps working, and the
evaluator already knows how to walk a `FormulaAST`.

### 4.2 Somewhere to put local names

```swift
evaluateNode(_ ast: FormulaAST, cells:, names:, functions:,
             callingCell:, currentSheet:, random:, simulation:, depth:)
```

Nine parameters, threaded through every case by hand, and **no environment**. `LAMBDA` and
`LET` both introduce names that shadow the workbook's — `_xlpm.x` is not a defined name, and
looking it up through `NameResolver` would either fail or, worse, find a workbook name that
happens to share the spelling.

The addition is a tenth parameter — `bindings: [String: CellValue]` — consulted in the
`.namedRange` case *before* the resolver. Small, but it touches the signature every case
already passes along, and that signature is nine parameters long today. **This is the moment
to introduce an `EvaluationEnvironment` struct** and pass one value instead of ten
arguments; doing it while adding the tenth is cheaper than doing it later, and a good deal
cheaper than not doing it.

### 4.3 The rest, which is smaller than it looks

| Need | Where it comes from |
|---|---|
| Recursion bound | `depth` already exists and is already threaded |
| `ISOMITTED` | `EvaluationContext.arguments` already carries the *unevaluated* trees, and `FormulaAST` already has `.missing` |
| `MAP`, `BYROW`, `BYCOL`, `REDUCE`, `SCAN`, `MAKEARRAY` | ordinary functions once a lambda is a value; each is a loop over `CellMatrix`, which already exists |
| Calling a named lambda | `function("MYLAMBDA", args)` already reaches the registry and fails there — the fallback is to ask `NameResolver`, which already returns `.formula(FormulaAST)` |

---

## 5. Two things Excel does that are worth refusing

**Recursion without a base case.** A `LAMBDA` may call itself by name, which is how
spreadsheet authors write loops. `depth` bounds it, and the answer at the bound should be
`#NUM!` — Excel's own answer — rather than a trap. The `RecursionAuditor` rule that every
recursive function needs a guard-driven base case applies to *our* code; a user's formula is
data, and the bound is the guard.

**`LAMBDA` as a value in a cell.** `=LAMBDA(x,x+1)` alone in a cell displays `#CALC!` in
Excel — a function is not a value a grid can show. Worth reproducing exactly, because the
alternative is showing something plausible.

---

## 6. Sequencing, and what each step is worth

| # | Step | Ends when | Cost |
|---|---|---|---|
| 1 | `EvaluationEnvironment` — the nine parameters become one value | every test still passes, no behaviour change | mechanical, one file |
| 2 | `LET` | `LET(a,2,a*3)` is 6 | small: bindings, no new `CellValue` case |
| 3 | Named `LAMBDA` — shapes ① and ② | `randomNormal(0,1)` answers | the 10,801 calls |
| 4 | `CellValue.lambda`, then `MAP`/`REDUCE`/`SCAN`/`BYROW`/`BYCOL`/`MAKEARRAY` | a lambda can be passed | **breaking**: a public enum case |
| 5 | `ISOMITTED` | | trivial once ④ lands |
| 6 | Shape ③, the immediately-invoked form | `LAMBDA(…)(F8,F9)` parses | upstream in SwiftXLSX |

**Steps 1–3 need no breaking change and reach the measured demand.** A named `LAMBDA` called
by name is `function(name, args)` where the name resolves to `.formula(LAMBDA(…))`; bind the
arguments, evaluate the body. `CellValue` is untouched, because a lambda that is only ever
*called* never has to *be* a value.

Step 4 is where the public enum gains a case, and it buys the six higher-order functions —
which the corpus does not call at all. **That is the natural place to stop and reconsider.**

---

## 7. Open questions

- **Does `_xlpm.` survive the reader?** The parser produces `namedRange("_xlpm.x")` with the
  prefix intact, which is what the binder wants. Confirm nothing downstream strips it, since
  `FunctionRegistry.canonical` strips two *other* prefixes and a third would be easy to add
  by accident.
- **Sheet-scoped lambdas.** A defined name can be scoped to a sheet; a lambda defined that
  way is only callable there. The resolver already handles scope, so this should be free —
  but it is untested and worth a case.
- **What `#CALC!` is.** `ExcelError` has seven cases and `#CALC!` is not among them. Adding
  it is a SwiftExcelCore change, and it is the honest answer for a lambda in a cell.

---

**Next action:** step 1, which is worth doing whether or not `LAMBDA` ever lands. Nine
positional parameters threaded through forty switch cases is a defect waiting for its
fortieth-first case, and the `LAMBDA` work is what makes the cost visible rather than what
creates it.
