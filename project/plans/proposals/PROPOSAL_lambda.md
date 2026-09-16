# Design Proposal: `LAMBDA`, `LET`, and the functions that take one

**Date:** 2026-09-16
**Status:** **Approved** 2026-09-16, all four open questions answered — see §15
**Category:** evaluation semantics

---

## 1. Objective

**Objective:** Evaluate `LAMBDA` and `LET`, the names a workbook binds to them, and the six
higher-order functions that take one — `MAP`, `REDUCE`, `SCAN`, `BYROW`, `BYCOL`,
`MAKEARRAY` — plus `ISOMITTED`.

**Master Plan Reference:** the unreviewed bucket, `logical` (11 rows, 8 of them this
family). Also the census: three of the eighteen function names this package cannot answer
are `LAMBDA`s, and **the most-called of the eighteen is one**.

---

## 2. Motivation

**Current situation.** `=myLambda(D2)` answers `#NAME?`. The registry has no `MYLAMBDA`, the
lookup fails, and nothing asks the workbook's defined names whether they hold a function.

**How the corpus works around it.** It does not. A workbook using `LAMBDA` is simply one this
package reads wrongly, and the `stale-value` checker has no way to tell that from a defect in
the file — which is the sharper cost, now that the checker exists.

**What the measurement says.** Scanning 2,240 workbooks for `_xlfn.LAMBDA` — the spelling a
stored formula uses:

| Measure | Found |
|---|---|
| Workbooks defining a `LAMBDA` | **2** |
| Workbooks using `LET` | **0** |
| Distinct `LAMBDA`s defined | 4 |
| Calls to one | **10,802** |

**A correction is folded into that table.** The first census reported `RANDOMNORMAL` — 10,801
calls, more than fifty times the next unanswerable name — as Crystal Ball's, on the strength
of the name and of `CB.RECALCCOUNTERFN` appearing in the same sweep. It is a `LAMBDA`:

```
randomNormal = _xlfn.LAMBDA(_xlpm.x, _xlpm.y,
                 _xlpm.x + _xlpm.y * SQRT(-2*LOG(RAND())) * COS(2*PI()*RAND()))
```

Box–Muller, called once per cell across a 10,800-cell simulation grid. So the conclusion
drawn from the first census — *"the `LAMBDA` family has no measured demand"* — was wrong.

**And the provenance cuts against the demand argument.** The workbook is not a stranger's
production model. `randomNormal` was an early attempt to build the Risk Solver distribution
suite out of nothing but `LAMBDA` — **a first sketch of this package**, by its author, before
it was a package. The 10,801 calls are a prototype exercising its own idea 10,800 times, not
a third party depending on the feature.

That changes what the number means without changing what it counts. Read as *demand*, it is
one person's experiment. Read as *evidence about the format*, it is exactly as good as any
other file: Excel wrote it, Excel cached the answers, and the two calls with deterministic
results are the golden-path traces in §10. The honest reading is that this corpus contains
**no independent demand for `LAMBDA`** — and the sharper argument for implementing it is §12's
last paragraph, not this section's.

**The first scan was also wrong in the other direction**, and the reason is worth keeping:
searching for the string `LAMBDA` returns **134** workbooks, because every modern Excel writes
`<xcalcf:feature name="microsoft.com:LAMBDA_WF"/>` into `<extLst>` whether the file uses the
feature or not. A feature *declaration* is not a use.

---

## 3. Proposed Architecture

**New files**

- `Sources/SwiftExcelFunctions/EvaluationEnvironment.swift` — the nine arguments
  `evaluateNode` threads, as one value, plus the local bindings `LET` and `LAMBDA` need.
- `Sources/SwiftExcelFunctions/BuiltinLambdaFunctions.swift` — `LAMBDA`, `LET`, `ISOMITTED`.
- `Sources/SwiftExcelFunctions/BuiltinHigherOrderFunctions.swift` — `MAP`, `REDUCE`, `SCAN`,
  `BYROW`, `BYCOL`, `MAKEARRAY`.

**Modified**

- `FormulaEvaluator.swift` — `.namedRange` consults bindings before the resolver;
  `.function` falls back to the name table when the registry misses.
- `SwiftExcelCore/CellValue.swift` — **one new case** (§7), in step 4 only.

**Module placement.** All of it in `SwiftExcelFunctions`, which is where evaluation
semantics live per the master plan's source table. Nothing here is mathematics, so nothing
belongs in BusinessMath.

### 3.1 What the file actually contains

Three shapes, all from the two workbooks:

```
① named            maxEXP = _xlfn.LAMBDA(_xlpm.arr, _xlpm.y, MAX(_xlpm.arr)^_xlpm.y)
② called by name   =myLambda(D2)                                → 5
③ called in place  =_xlfn.LAMBDA(_xlpm.x,_xlpm.y, …)(F8,F9)     → 0.361457…
```

Two prefixes carry the format story. **`_xlfn.`** on the function, which
`FunctionRegistry.canonical` already strips. **`_xlpm.`** on every parameter, in the
declaration *and* the body — Excel marking "this identifier is a parameter, not a defined
name". It is a hint worth having and, per §12, **not** a thing to depend on.

### 3.2 What the parser already does

| Form | Result |
|---|---|
| `_xlfn.LAMBDA(_xlpm.x, _xlpm.x+1)` | ✅ `function("_XLFN.LAMBDA", [namedRange("_xlpm.x"), add(…)])` |
| `myLambda(D2)` | ✅ `function("MYLAMBDA", [cellRef(D2)])` |
| `_xlfn.LET(_xlpm.a, 2, _xlpm.a*3)` | ✅ |
| `MAP(A1:A3, _xlfn.LAMBDA(_xlpm.v, _xlpm.v*2))` | ✅ nested |
| `ISOMITTED(_xlpm.y)` | ✅ |
| `LAMBDA(…)(F8,F9)` | ❌ `unexpectedToken(expected: "end of expression", found: "(")` |

**Five of six parse today.** `LAMBDA` is syntactically an ordinary call and its parameters
are syntactically ordinary names. Only ③ needs a grammar SwiftXLSX does not have.

---

## 4. API Surface

```swift
/// Everything an evaluation needs, as one value instead of nine arguments.
public struct EvaluationEnvironment: Sendable {
    public let cells: any CellValueProvider
    public let names: NameResolver
    public let functions: FunctionRegistry
    public let callingCell: CellAddress?
    public let currentSheet: String
    public let random: (any RandomSource)?
    public let simulation: (any SimulationResultProvider)?
    public let depth: Int

    /// Names bound by an enclosing `LET` or `LAMBDA`, innermost last.
    public let bindings: [String: CellValue]

    /// A child environment with one more frame of names.
    public func binding(_ names: [String: CellValue]) -> EvaluationEnvironment
}
```

```swift
// SwiftExcelCore — step 4 only
public enum CellValue {
    // …
    /// A function: its parameters, its body, and the names it closed over.
    case lambda(parameters: [String], body: FormulaAST, captured: [String: CellValue])
}
```

The captured frame is **not** optional decoration — see §12, where its absence is the flaw
the adversarial review found in the first draft of this proposal.

---

## 5. MCP Schema

**N/A for steps 1–3.** They add no public entry point: `LAMBDA` is reached through
`FormulaEvaluator.evaluate`, whose signature does not change.

**Step 4 raises a real question and it is recorded rather than answered.** `CellValue` is
the wire type for every MCP surface built on this package, and a lambda has no JSON form
today. If a lambda escapes into a tool result it must serialise as something:

```json
{ "type": "lambda", "parameters": ["x", "y"], "body": "_xlfn.LAMBDA(…)" }
```

— the body as its **source text**, via `FormulaSerializer`, because that is the only form
that round-trips. Decided at step 4, not before.

---

## 6. Constraints & Compliance

**Concurrency.** `CellValue.lambda` carries `[String]`, `FormulaAST` and
`[String: CellValue]` — all `Sendable`, so the enum stays `Sendable` with no
`@unchecked`. `EvaluationEnvironment` is a value type over existing `Sendable` members.

**Equatable and Hashable.** `CellValue` is both, and both keep working: a lambda held as
*syntax* is comparable, where a Swift closure would not be. This is the whole of the
"`LAMBDA` does not fit Swift" worry and it dissolves under the right representation.

**Recursion.** `RecursionAuditor` requires a guard-driven base case for *our* functions. A
user's recursive formula is data, and the guard is `maxDepth` — see §12, where the current
bound turns out to be too low for the idiom.

**Safety.** No force unwraps; a missing binding is `#NAME?`; an arity mismatch is `#VALUE!`;
a lambda alone in a cell is `#CALC!` (§15).

**Determinism.** `randomNormal` calls `RAND()`, so its results stay `notComparable` to the
oracle for the reason every volatile function is. Implementing `LAMBDA` does not make a
Monte Carlo grid reproducible and is not meant to.

---

## 7. Source & API Compatibility

| Step | Breaking? |
|---|---|
| 1 `EvaluationEnvironment` | **No.** `evaluateNode` is private; the public `evaluate` overloads keep their signatures |
| 2 `LET` | No — a new registry entry |
| 3 named `LAMBDA` | No — a new registry entry plus a resolver fallback |
| 4 `CellValue.lambda` | **Yes.** A new case on a public enum in SwiftExcelCore |
| 5 `ISOMITTED` | No |
| 6 the IIFE form | No, but it is an upstream parser change |

**Step 4 is the only break, and it is a real one.** Every exhaustive `switch` over
`CellValue` stops compiling — in this package, in SwiftXLSX, in BusinessMathExcel, and in
anything else built on SwiftExcelCore. It is a minor-version change for the whole family and
should land with one.

**Incremental adoption:** yes, and the order is chosen for it. Steps 1–3 reach every one of
the 10,802 measured calls without the break, because **a lambda that is only ever called
never has to be a value**.

---

## 8. Backend Abstraction

N/A. Nothing here is compute-intensive; the cost of a `MAP` is the cost of the body it runs.

---

## 9. Dependencies

**Internal:** `FormulaAST` and `CellValue` (SwiftExcelCore), `NameResolver`,
`FunctionRegistry`, `CellMatrix`.

**External:** none.

**Upstream, for step 6 only:** SwiftXLSX's `FormulaParser` must accept a call applied to a
parenthesised expression. That is the fourth SwiftXLSX defect this corpus work has found and
belongs in the same batch as the other three.

---

## 10. Test Strategy

**Categories.** Golden path from the corpus; binding and shadowing; arity; recursion bound;
`ISOMITTED`; each higher-order function over a known matrix; the refusals.

**Reference truth.** The two corpus workbooks, which carry Excel's own cached answers, plus
Microsoft's published examples for the six higher-order functions.

**Validation traces — Excel's values, from `lambda.xlsx`:**

```
myLambda = LAMBDA(x, x+1)              D2 = 4        D3 = myLambda(D2)     → 5
maxEXP   = LAMBDA(arr, y, MAX(arr)^y)  C4 = 3        D4 = maxEXP(C4,C4)    → 27
```

Those two become the golden-path assertions. The second is the better test of the pair: it
has two parameters, uses one of them twice, and its answer (27) is wrong under every
plausible binding mistake — `MAX(3)^3` is 27, while swapping the parameters is also 27, so
the test must use **different** values for the two arguments to be worth anything. Corrected
trace: `maxEXP(C4, C2)` is not in the file, so the test supplies its own — `MAX({1,5,3})^2`
= 25 — and the corpus pair covers the call path.

**Not testable against the corpus:** `randomNormal`, which calls `RAND()`. Its 10,801 cells
stay `notComparable`.

---

## 11. Architecture Decision Review

**ADR check**

- [x] Reviewed `architecture_decisions.md`
- [x] Supersedes an existing ADR? **No**
- [x] Amends an existing ADR? **No**
- [x] New ADR required? **Yes, at step 4** — adding a case to a public enum in a shared core
      package is exactly the kind of decision that outlives the discussion.

**New ADR draft (step 4)**

- **Title:** A lambda is a value, and it is held as syntax
- **Category:** api
- **Key decision:** `CellValue` gains `.lambda(parameters:body:captured:)` rather than a
  closure or a side table, because syntax keeps `Equatable`, `Hashable` and `Sendable` while
  a closure breaks all three and a side table cannot express a lambda that is returned.

---

## 12. Adversarial Review

**Strongest case for a different approach.**

Do not touch `CellValue` at all. `EvaluationContext.arguments` already carries the
**unevaluated** argument trees, so `MAP(A1:A3, LAMBDA(v, v*2))` can take its lambda from
`arguments[1]` as a `FormulaAST` and never as a value. A named lambda resolves through
`NameResolver` to `.formula(FormulaAST)`, which is also already there. On that route every
one of the six higher-order functions is implementable, `LET` is implementable, all three
corpus shapes work — **and nothing breaks.**

That alternative is better than the proposal on every axis except one, and a reviewer would
be right to push hard for it.

**Where this design is most likely wrong.**

1. **The first draft of this proposal had no captured environment**, and that was a real
   error, not a simplification. `LAMBDA(x, LAMBDA(y, x+y))` returns a function that must
   remember `x`; a `.lambda(parameters:body:)` with no `captured:` is not a closure and
   currying silently returns the wrong answer. Excel supports this and people write it. The
   case gained a third payload because the counterargument found it.
2. **Depending on `_xlpm.` to identify parameters.** Excel writes it, but a file from
   LibreOffice, Google Sheets, or a hand-built fixture may not, and the binder would then
   look a parameter up as a workbook name — finding either nothing or, worse, a real name
   that happens to share the spelling. **Bind by the parameter list the `LAMBDA` node
   declares**, whatever it is spelled; treat `_xlpm.` as a hint for diagnostics only.
3. **`maxDepth` is 256, and it counts AST nodes, not calls.** Recursion by name is how
   spreadsheet authors write loops, and a recursive lambda over a few hundred items will hit
   the bound long before Excel does — while a modestly nested arithmetic expression has
   already eaten part of the budget. A separate, larger *call*-depth counter is needed, and
   the proposal did not have one.
4. **"Two workbooks" may be an artefact of one corpus.** This is one person's document
   tree, and `LAMBDA` is five years old. A different corpus could show ten times the use or
   none at all. The measurement bounds *this* corpus and nothing else.
5. **The demand is self-referential, and that is the weakest part of the case.** The 10,801
   calls are the author's own prototype of this package — an attempt to build the Risk Solver
   suite in `LAMBDA` alone. Counting them as evidence that users need `LAMBDA` is close to
   counting one's own footprints. **The measurement does not support "there is demand"; it
   supports "when it is used, it is used heavily",** which is a different and smaller claim.
   The case for implementing rests on §12's closing paragraph — the checker cannot afford a
   class of formulas it reads wrongly and silently — and not on this count.

**What an experienced critic would say.**

> "You are changing a public enum in a shared core package to serve two workbooks out of
> 2,240 — one of them your own prototype — when the route that breaks nothing covers every
> line of evidence you have."

**Why we are proceeding anyway.** Because the side-table route is a 90% solution whose
last 10% is invisible until it is wrong: it cannot express a lambda **returned** by a
lambda, **bound** by a `LET`, or **chosen** by an `IF`. All three are legal Excel, all three
would evaluate to something plausible rather than to an error, and a checker that reports
workbook defects cannot afford a class of formulas it reads wrongly and silently. The
decision is completeness over compatibility, taken deliberately, at a minor version, and
**after** steps 1–3 have shipped the measured demand without it.

---

## 13. Alternatives Considered

**Alternative 1 — lambdas as unevaluated ASTs, no `CellValue` case** (the counter-design
above)
- *Advantage:* no breaking change; uses machinery that already exists; covers every corpus
  shape and all six higher-order functions.
- *Disadvantage:* a lambda cannot be returned, bound, or chosen at runtime — and each of
  those fails by producing a plausible value rather than an error.
- *Why not:* §12. It is the right **first** implementation and the wrong **final** one, which
  is why steps 1–3 are exactly it.

**Alternative 2 — a Swift closure in the enum:
`case lambda(@Sendable ([CellValue]) throws -> CellValue)`**
- *Advantage:* the obvious shape; composes with Swift.
- *Disadvantage:* `CellValue` stops being `Equatable` and `Hashable` on the spot, which
  breaks `CellMatrix`, every test assertion, and the oracle's comparison. A closure also
  cannot be serialised for MCP or written back to a file.
- *Why not:* this is the "`LAMBDA` does not fit Swift" intuition, and it is an artefact of
  this representation rather than of the language.

**Alternative 3 — a side registry keyed by name, outside `CellValue`**
- *Advantage:* no enum change; names stay where names live.
- *Disadvantage:* a registry is keyed by name and an anonymous lambda has none; it also
  needs a lifetime, which nothing in this package has.
- *Why not:* solves less than Alternative 1 at more cost.

**Alternative 4 — refuse the family, and mark all eight rows out of scope**
- *Advantage:* costs nothing; five categories are already closed this way in part.
- *Disadvantage:* the honest reason would have to be "no demand", and the measurement says
  otherwise — 10,802 calls, the largest single block of unanswerable calls in the corpus.
- *Why not:* the out-of-scope marks this project has made are all defensible on their own
  terms (`INFO` reports a machine, `STOCKHISTORY` calls a web service). This one would not be.

---

## 14. Future Directions

- **The `_xlpm.` hint could drive diagnostics** — a body referring to `_xlpm.z` where no `z`
  is declared is a defect in the workbook, and the checker could say so.
- **A recursive lambda could be recognised and bounded specially**, reporting `#NUM!` with
  the recursion named rather than a generic depth error.
- **`LET` could feed the optimiser.** A `LET`-bound name is a common subexpression the author
  has already identified, which is the thing `BytecodeOptimizer` does not eliminate.
- **Lambdas in the Solver path** — a model whose objective is a named lambda is a shape
  `SpreadsheetFunction` could call directly.

---

## 15. Open Questions — answered

**1. `#CALC!` does not exist. → Approved: add it.** `ExcelError` gains an eighth case in
SwiftExcelCore, landing in the same release as `CellValue.lambda`. It is the honest answer
for a lambda alone in a cell, and `ERROR.TYPE` — which switches over every case — gains the
row Excel gives it (`#CALC!` has no `ERROR.TYPE` number in Excel's table; it returns `#N/A`,
and that is what to reproduce).

**2. What call depth is right? → Measured, not chosen.** `conformance-workbook depth` emits
a workbook that asks Excel where its own limits are, in four separate sections:

| Section | Asks | Needs a name |
|---|---|---|
| nesting | how deep an expression may be, with no recursion | no |
| thin | how deep a recursive `LAMBDA` goes | yes |
| fat | the same with three more calls per level | yes |
| iteration | whether `REDUCE` over a long sequence is bounded separately | no |

**Thin against fat is the question that decides the instrument.** Both failing at the same
depth means the budget is counted in *calls*, and a call counter suffices. The fat one
failing earlier means the budget is *stack*, and a call counter is the wrong instrument
altogether.

A canary row — `REDUCE` over three cells, answer 6 — guards the whole sheet: every row
depends on `_xlfn.` and `_xlpm.` being written the way the format wants, and a file that gets
them wrong shows `#NAME?` everywhere, which looks exactly like Excel refusing the depth.

**3. Sheet-scoped lambdas. → Approved, with a test.** The resolver already takes a sheet, so
this should cost nothing; "should" is what the test is for.

**4. Does anything strip `_xlpm.`? → Investigated: no, and two things were found.**

- **Nothing anywhere knows about it.** `_xlpm` appears in no file of SwiftXLSX,
  SwiftExcelCore or this package. It survives the parser — `namedRange("_xlpm.x")` — and the
  serializer writes it back unchanged. `FunctionRegistry.canonical` strips `_XLL.` and
  `_XLFN.` and is only ever applied to *function* names, never to a `.namedRange` payload.
- **Name resolution is case-insensitive** (`NamedRangeCollection.resolve` lowercases both
  sides), so parameter binding must be too, or a body writing `_xlpm.X` will not find the
  `_xlpm.x` its `LAMBDA` declared. Excel is case-insensitive about names, so this is the
  correct behaviour and not merely a compatibility measure. **Bindings are therefore keyed
  case-insensitively**, which §4's `[String: CellValue]` does not say and the implementation
  must.
- **And a fifth upstream defect, found on the way:** SwiftXLSX's *writer* emits no
  `<definedName>` elements at all. It reads them and drops them, so a workbook saved through
  this package loses every defined name it had — and a workbook generated by it can carry
  none. That is why the limits workbook asks its reader to add two names by hand. Injecting
  the XML into the saved archive would be a second writer, which is the thing the package
  split exists to prevent.

## 16. Documentation Strategy

**Documentation Type:** Narrative article required.

- Combines 3+ APIs? **Yes** — environment, registry, resolver, and six functions.
- Explanation needs 50+ lines? **Yes.**
- Needs background? **Yes** — closures, capture and shadowing are not spreadsheet concepts,
  and the reader is a spreadsheet person.

**Article name:** `EvaluatingLambdas.md` — no Swift symbol shares it.

---

**Next action:** step 1, `EvaluationEnvironment`, which is worth doing whether or not this
proposal is approved. Nine positional parameters threaded through forty switch cases is a
defect waiting for its forty-first case; the `LAMBDA` work makes the cost visible rather
than creating it.
