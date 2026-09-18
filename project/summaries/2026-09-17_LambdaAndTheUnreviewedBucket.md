# Session summary — LAMBDA, and the bucket reaches zero

**Date:** 2026-09-17 (ran into 2026-09-18)
**Repos touched:** SwiftExcelFunctions, SwiftExcelCore (0.11.0, 0.12.0), SwiftXLSX (0.26.1 →
0.29.0)
**End state:** 591 functions registered · 1,736 tests · gate 45/45 uncached · zero warnings ·
`unreviewed` (EXCEL) **0**

---

## What this session was

It began as "finish the defined-name round trip" and ended with the unreviewed bucket closed.
Four threads, in order:

1. The corpus round trip that licenses the defined-name design
2. `LAMBDA`, all six proposal steps plus one the proposal did not have
3. Two conformance rounds, one of which overturned a decision the evaluator was built on
4. The unreviewed bucket: 87 rows → 0

---

## 1. The round trip: 161,901 names, zero differences

`PROPOSAL_defined_names.md` chose to **derive** a name's refers-to text from its target rather
than keep a copy beside it — one fact, one place, nothing that can drift. The cost is that
every rule the writer applies has to be right; the reason to accept it is that being right is
*checkable*.

| | 0.26.1 | 0.26.2 |
|---|---:|---:|
| Workbooks (1,022 with names) | 2,240 | 2,240 |
| Names compared | 161,901 | 161,901 |
| **Came back different** | **54** | **0** |

The 54 were all `_bdm.<guid>.edm` external-link names in three versions of one operating
model. Two writer defects: a whole-sheet span matched both short-form branches and the column
branch won arbitrarily; and `[1]AVP!` was being quoted when Excel leaves it bare. Both fixed.

161,901 is also what the census reached by counting `<definedName>` elements in raw XML, where
this counted them through the type the evaluator uses. **Two independent routes to the same
number** is evidence the reader is not quietly dropping a shape.

### Three ways the *tool* failed first

Worth more than the table, because they recur:

- **It printed only at the end** and was killed after an hour with nothing to show — the same
  failure the census was abandoned for twice. Now a row per workbook, flushed, with the file
  as its own resume state.
- **Path order put the expensive tail first.** It reached workbook 55 — 40 MB — and sat there
  at 4 GB resident while 2,185 files it could have measured in minutes queued behind. The
  corpus median is 29 KB. Smallest-first now.
- **A workbook killed the process.** Not a throw: `SIGTRAP` from SwiftXLSX's writer at a value
  near 1e19. The tool now names the workbook it was holding and goes on past it.

## 2. LAMBDA

All six steps, plus a prerequisite §12 missed.

| Step | |
|---|---|
| 1 | `EvaluationEnvironment` — nine threaded arguments became one value |
| — | **Lazy branching** — not in the proposal |
| 2 | `LET` |
| 3 | Named `LAMBDA` + recursion |
| 4 | `CellValue.lambda` + `ExcelError.calc` (SwiftExcelCore 0.11.0) |
| 5 | `ISOMITTED` |
| 6 | The higher-order six, and the IIFE grammar (`FormulaAST.call`, 0.12.0) |

**The prerequisite.** Setting up `LET`, I checked whether `IF` short-circuits. It did not —
`EvaluationContext` said so outright: *"This is not lazy evaluation. Every argument is still
evaluated, exactly once."* `CHOOSE`'s doc explained why that seemed fine: an unchosen `1/0`
becomes `#DIV/0!` and is discarded.

**That holds for errors and nothing else.** An unchosen branch that *recurses* does not become
an error value — it runs. The canonical recursive lambda is `IF(n<=0, 0, 1 + f(f, n-1))`, so
under eager arguments the recursive arm fires on the base case, forever. **No LAMBDA could
have worked until this was fixed**, and ten tests were written before the fix, six of them red.

`LazyBranch` decides *what to evaluate* and never *what the answer means* — it hands `IF` and
`CHOOSE` sentinel arguments and asks which they would return, so there is never a second copy
of truthiness.

### The known limitation, stated rather than hidden

Recursion reaches **~160 levels, not Excel's 4,096.** `evaluateNode` recurses, a lambda level
costs ~3.2 nodes, and `maxNodeDepth` (512) bites first. A larger constant is exactly what does
not fix it — 512 was measured against the stack, and past it a refusal becomes `SIGSEGV`. The
fix is an explicit stack in `evaluateNode`; the cheap workaround is a thread with a bigger one.

`REDUCE` over 2,000 elements works, because iteration is not recursion. Excel draws the same
line: `REDUCE` reached 8,192 with no limit found.

## 3. Conformance rounds 6 and 7

**Round 6 reversed a decision the evaluator was built on.** A `LAMBDA` may **not** be called
with fewer arguments than it declares.

```
LAMBDA(x,y,IF(ISOMITTED(y),1,2))(7)     →  #VALUE!
LAMBDA(x,y,IF(ISOMITTED(y),1,2))(7,8)   →  2          ← control
LAMBDA(x,y,x)(7,8,9)                    →  #VALUE!
```

I had implemented the opposite, reasoned from Microsoft's own `ISOMITTED` pattern being
unusable otherwise. It *is* unusable otherwise, and the answer is still no. **Sixth time
documentation has been wrong here, and the first time it was this project's own reasoning
about the documentation.**

Two of my six round-6 rows were malformed — `f(7,,)` is three argument positions, not a
skipped second. Round 7 asked properly and settled everything:

- An empty argument **position** is what `ISOMITTED` reports on: `f(7,)` is omitted, `f(7)` is
  refused.
- A **named** lambda obeys the same arity rule. There is no second rule.
- `ERROR.TYPE` of `#CALC!` is **14** — measured, where it had been the last value in that
  function taken on Microsoft's word.

Round 7 needed **nothing added by hand**: `probeOptional` is written into the file by this
family's own `<definedName>` writer. Two earlier rounds were lost to a `depthProbe` that had
to be added manually and never was. Every question is now a control.

## 4. The unreviewed bucket: 87 → 0

| Category | Rows | How it closed |
|---|---:|---|
| logical | 11 | 8 with `LAMBDA`, then `IFS`, `SWITCH`, `XOR` |
| math | 19 | All, `AGGREGATE` included |
| database | 12 | All, from one criteria-range design |
| lookup | 24 | 16 implemented; 8 out of scope with written reasons |
| financial | 21 | All, including the four `ODD*` bonds |

**Final: 473 have · 25 out of scope · 20 bindable · 1 new.**

The bar was *classified*, not implemented — and **73 of the 87 were implemented anyway**,
because once the criteria matcher, `CellMatrix` and `LAMBDA` existed most were a handful of
lines each.

**Every one of the 87 had zero corpus usage.** The census columns are populated — 69 EXCEL
rows carry counts, `IFERROR` topping at 168,779 — so that zero is a measurement. None of this
was needed to read the 2,240 workbooks; the case was completeness, which is a weaker argument
and was worth saying before the work rather than after.

### The quasi-coupon bug

The one to remember. My first `ODDLPRICE` measured the odd last period as a single
settlement-to-maturity fraction. On Microsoft's example that period spans **1⅓ quasi-coupon
periods**, so it earns 1⅓ coupons where the fraction says ⅔ of one. The bond priced **1.15
points light** — not a rounding, and invisible without a reference.

What caught it: insisting a price function and its yield function **invert each other across a
range** of yields, not only at the published figure. A single published number can be matched
by an implementation that is wrong twice; a round trip cannot.

---

## Upstream releases

| | |
|---|---|
| SwiftExcelCore **0.11.0** | `CellValue.lambda`, `ExcelError.calc` |
| SwiftExcelCore **0.12.0** | `FormulaAST.call` — the immediately-invoked form |
| SwiftXLSX **0.26.1** | a number past `Int.max` killed the process |
| SwiftXLSX **0.26.2** | whole-sheet spans and external references keep their form |
| SwiftXLSX **0.27.0** | a lambda cell is written as the formula cell it is |
| SwiftXLSX **0.28.0** | `LAMBDA(…)(args)` parses |
| SwiftXLSX **0.29.0** | whole columns stay whole in a shared formula; `_x000D_` is a newline |

Both source-breaking changes were taken deliberately, at minor versions, after the measured
demand had shipped without them.

---

## Things that bit, and would bite again

**A fixture rotted for the sixth time.** `StaleValueChecker` used `FILTER` as its example of
"a formula we cannot evaluate". Implementing `FILTER` made it find a real disagreement in a
workbook built to have none. It now uses `RTD`, which is refused *by design* rather than by
backlog and cannot rot the same way.

**A test failed by succeeding.** `UnreviewedCoverageTests` asserted `total > 0` as a parse
guard, written when emptying the bucket was distant. Inverted rather than deleted — the bucket
refills quietly when a new Excel release lands.

**The gate passed a rule by coincidence.** `logging.catch-without-logging` matches the
substring `.error(`, and `CellValue.error` spells the same as `Logger.error`. **55 of 108
catch blocks here satisfied it while logging nothing.** Found only because an unrelated
refactor removed the coincidence. Proposal written
(`quality-gate-swift-project/plans/proposals/ACatchThatSwallows.md`); both halves have since
landed upstream, and this repo now declares `logging.errorValueTypes`.

**`quality-gate` replays a cached build.** It reported clean while four warnings existed. Every
gate run in this session after that used `--no-cache`.

**Three test expectations were wrong where the code was right.** Microsoft's financial examples
are dated **2008** — a leap year — and I typed 2018, which changes February's day count and
every actual/360 fraction with it. Also: five of seven published pairs for `SUMX2MY2`, and two
bill examples merged that use different discount rates.

---

## Where to pick up

Nothing is blocked. In rough order of value:

1. **The evaluator's stack ceiling.** ~160 recursion levels against Excel's 4,096. Needs an
   explicit stack in `evaluateNode` — a core rewrite, and the honest fix.
2. **147 `PSI` rows** remain unreviewed. They need a simulation engine, not a classification.
3. **`GROUPBY` / `PIVOTBY`** are implementable now that `LAMBDA` exists; classified out of
   scope on zero demand, and the classification should move if one appears in a corpus.
4. **The sibling logging rules.** §7 of `ACatchThatSwallows.md` notes `logging.silent-try` and
   `hasPrintOrNSLog` use the same substring technique that produced a 51% false-negative rate.
   Neither has been measured.
5. **`ERROR.TYPE` codes 8–13** (`#GETTING_DATA`, `#SPILL!`, …) are unrepresentable here and
   unmeasured. Only `#CALC!` was reachable.
