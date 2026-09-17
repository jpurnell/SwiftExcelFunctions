# Excel's evaluation limits, measured

**What this is:** the depth limits Excel enforces on formulas, established by experiment
because Microsoft documents one of them and not the others.

**Measured against:** Microsoft Excel for Mac **16.114** (`AppVersion 16.0300`,
`calcId 191029`), September 2026, on macOS 27. Seven rounds.

**Reproduce it:**

```
swift run conformance-workbook depth ~/Desktop/limits.xlsx
# open it, let it calculate, save it
swift run conformance-workbook depth-read ~/Desktop/limits.xlsx
```

---

## The answers first

| Question | Answer |
|---|---|
| How deep may an expression nest? | **65 function calls.** 66 is refused |
| When is that enforced? | **When the file loads** — Excel deletes the cell and reports the workbook as damaged |
| How deep may a `LAMBDA` recurse? | **4,095 invocations.** The 4,096th is `#NUM!` |
| Is the budget calls, or stack? | **Calls.** Three extra function calls per level move the limit not at all |
| Can `IFERROR` trap the refusal? | **No** |
| Do nesting and recursion share a budget? | **No — two separate counters** |
| Is `REDUCE` bounded like recursion? | **No limit found to 8,192** |
| May a `LAMBDA` be called with fewer arguments than it declares? | **No.** `#VALUE!` |

Microsoft documents exactly one line of that: *"Nested levels of functions: 64."* Everything
else here is unpublished, and the published number needs a footnote — see §1.

---

## Why anyone needs this

An evaluator that reads Excel files has to stop somewhere. Recursion without a bound is a
crashed process; a bound chosen by taste is a guess in both directions at once. Too low and
you refuse formulas Excel computes, which makes you wrong about somebody's working
spreadsheet. Too high and you exhaust a stack on a formula Excel would have refused, which
makes you wrong about a broken one.

`LAMBDA` makes this pressing rather than theoretical. A recursive `LAMBDA` is how a
spreadsheet author writes a loop — there is no other construct for it — so the bound is not
an edge case, it is the feature's working range.

This package's own bound was `maxDepth = 256`, incremented once per AST node. Against the
measurements below that is wrong three ways at once: an order of magnitude too small,
counting the wrong thing, and conflating two budgets Excel keeps apart.

---

## The method

**A workbook is the instrument.** Formulas are written into cells, the file is opened in
Excel, Excel calculates and saves, and the cached values are read back out. Excel is the only
authority on what Excel does, and this is the only way to ask it. Documentation has been
wrong five times in this project's life; on this subject it is mostly silent.

Three design rules, each of which earned its place by the round that went wrong without it.

**Canaries.** Two rows whose answers are known: `REDUCE` over three cells (6) and a
self-applying `LAMBDA` at depth 3 (3). Every formula in the sheet depends on the `_xlfn.` and
`_xlpm.` prefixes being written the way the file format wants, and a file that gets them
wrong shows `#NAME?` in every row — which looks exactly like Excel refusing the depth. The
reader reports the canaries first and stops if either is wrong.

**Controls.** Once a question is answered, its row stays in the sheet with its known answer.
A round that goes wrong then says so, instead of looking like news.

**A round stamp.** The layout is written into the file, and the reader refuses a file whose
round is not the one it expects. §6 is the story of why.

---

## 1. Expression nesting: 65, enforced at load

The first sheet asked for `IF(TRUE, IF(TRUE, … , d), 0)` at depths 2 through 128.

Excel refused to open it:

```xml
<removedRecord>Removed Records: Formula from /xl/worksheets/sheet1.xml part</removedRecord>
```

That looked like a failed round. It was the measurement. Excel had stripped **exactly** the
four cells asking for 66, 70, 100 and 128 — and left every other formula in the sheet
untouched:

```
kept:    2, 8, 32, 60, 62, 63, 64, 65
removed: 66, 70, 100, 128
```

So the limit is 65 calls deep and the bracket has no slack in it at all.

**The manner of the refusal is the more useful half.** Excel does not evaluate an over-nested
formula and return an error. It refuses the *file*: the cell is deleted, the workbook is
reported as damaged, and the user is shown a repair dialog. An over-nested formula is not a
`#VALUE!`; it is a file Excel will not accept.

Two consequences worth stating:

- An evaluator cannot faithfully reproduce this, because it has nothing to delete. The
  honest analogue is for the *reader* to report it — and a file that arrives with 66-deep
  nesting was written by something other than Excel.
- **A workbook with a formula missing may have been repaired rather than authored that way.**
  Anything auditing spreadsheets should know that the absence of a formula is sometimes a
  fact about Excel rather than about the author.

On the documented 64: it is consistent with a measured 65 if the outermost call is not
counted as nesting. Both numbers are correct under their own reading, and an implementation
should key off the measured one.

---

## 2. Iteration is not the same question

`REDUCE(0, SEQUENCE(n), LAMBDA(a,v,a+v))` was run at the same ladder. It reached **8,192**
without complaint, answering 33,558,528 — which is 8192 × 8193 / 2 to the digit, so the
iteration really ran rather than short-circuiting.

No limit was found. `REDUCE` iterates rather than recursing, and whatever bounds recursion
does not bound it at this scale.

---

## 3. Recursion: 4,096, counted in calls

### The self-application trick

Measuring recursion needs a `LAMBDA` that calls itself, and a `LAMBDA` calls itself **by
name** — which means a defined name, which means a manual step, which cost two rounds
(§4, §5).

There is a way around it. A `LAMBDA` cannot call itself anonymously, because there is nothing
to call — but it can take *itself* as a parameter and invoke that:

```
LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1)))(LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1))), 4094)
```

That is the immediately-invoked form applied to a self-passing body, and it needs nothing
added to the file. It is not an invention of this experiment: a workbook in the corpus —
someone's Monte Carlo model — writes an immediately-invoked `LAMBDA` for a Box–Muller normal
draw, so Excel demonstrably accepts the form. The canary proves it each round rather than
trusting that.

### The number

```
f(f, 4094)  →  4094     4,095 invocations, counting the base case
f(f, 4095)  →  #NUM!    4,096
```

**The limit is 4,096 exactly.** That it is a power of two is worth noticing: it reads like a
fixed frame table rather than a heuristic, which makes it the kind of number that stays put
across versions.

### Calls, not stack

The question an implementation actually needs answered is *what* is being counted. If the
budget is stack, a body doing more work per level should fail sooner, and a call counter
would be the wrong instrument entirely.

So the ladder was run twice, with two bodies that return the same value and do different
amounts of work:

```
thin   IF(n<=0, 0, 1 + f(f, n-1))
fat    IF(n<=0, 0, SUM(1, ABS(SIGN(n))) - 1 + f(f, n-1))
```

Three extra function calls per level. Both refuse at exactly the same depth — 4,094 works,
4,095 does not, for each — confirmed at the boundary itself rather than a thousand levels
short of it.

**The budget is counted in calls.** A call counter is the right instrument.

### The refusal is not catchable

Every row of the recursion ladder was originally wrapped:

```
IFERROR(<recursion>, "refused")
```

Every one of them cached `#NUM!` anyway. `IFERROR` sits on the same stack that ran out, so it
never gets the chance to handle anything.

This is the subtlest finding here and the easiest to get wrong by being helpful: an evaluator
that produced `#NUM!` through its own error-handling path would be **more forgiving than
Excel**, and a formula would recover where the real thing does not.

---

## 4. Two budgets, not one

If nesting and recursion drew on one counter, a deep recursion reached through nested `IF`s
would fail sooner than the same recursion reached directly.

```
0 nested IFs  around a 4,090-deep recursion  →  4090
2                                            →  4090
4                                            →  4090
8                                            →  4090
32                                           →  4090
60                                           →  4090
```

4,090 + 60 is 4,150, comfortably past the 4,095 limit. A shared counter had to refuse and did
not.

**They are separate counters**, and an implementation should keep them separate too.

---

## 5. Arity is exact, and the documentation is not

Round six asked whether a `LAMBDA` may be called with fewer arguments than it declares. The
question matters because `ISOMITTED` exists, and Microsoft's documented pattern for an optional
parameter —

```
LAMBDA(x, [y], IF(ISOMITTED(y), x, x+y))
```

— is unusable unless the answer is yes. The `[y]` is a convention for readers; Excel's formula
language has no syntax for an optional parameter.

```
LAMBDA(x,y,IF(ISOMITTED(y),1,2))(7)      →  #VALUE!
LAMBDA(x,y,IF(ISOMITTED(y),1,2))(7,8)    →  2
LAMBDA(x,y,x)(7,8,9)                     →  #VALUE!
```

**Arity is exact.** The middle row is the control and it answers, so the other two mean what
they say. This evaluator had been built on the opposite assumption, reasoned from the
documentation, and the assumption was wrong — the sixth time documentation has been wrong in
this project's life and the first time it was *this project's own reasoning about* the
documentation rather than the documentation itself.

Which leaves `ISOMITTED` with nothing to report, unless an empty argument *position* —
`f(7,)`, two positions with the second left blank — is a different thing from a missing one.
Round six asked that with `f(7,,)`, which is three positions against two parameters and
therefore measured the arity rule again. **Unresolved, and asked properly in round seven.**

A second reading worth keeping: `ERROR.TYPE(LAMBDA(x,x))` is `#N/A`, not a number. An uncalled
lambda handed to a function is a **value**, not an error — `#CALC!` is what a *cell* shows, not
what a lambda *is*. So the published `ERROR.TYPE` code for `#CALC!` is still unmeasured, and
round seven asks it of a cell that actually holds one.

---

## 6. Three ways the instrument lied, and what fixed each

The findings above took five rounds. Two of the extra rounds were the instrument's fault, and
the failures are more transferable than the numbers.

### A probe that passes either way measures nothing

The budget question was asked first with a **3,000**-deep recursion inside 60 nested `IF`s.
All six rows answered 3000, and it read exactly like evidence for separate budgets.

It was evidence for nothing. `3000 + 60` is 3,060 — comfortably under the limit — so the
probe succeeds whether the counters are shared or separate. **A test that passes under both
hypotheses distinguishes nothing**, and this one would have been believed, because it
produced numbers and the numbers were consistent.

The fix was arithmetic, not cleverness: move the recursion to five short of the limit, so a
shared counter *must* refuse.

### A missing precondition looks exactly like a result

Two rounds asked Excel to evaluate `depthProbe(n)` for a `depthProbe` that had to be added by
hand. It was not added, so every row was `#NAME?`, which `IFERROR` turned into `"refused"` —
and the reader dutifully reported *first refused: 1*.

The tell was in the data: **no recursion limit can refuse at depth 1.** A reading that cannot
be told apart from a setup failure is not a reading. The reader now checks the workbook's name
table and says what is missing; and the self-application trick removed the precondition
altogether.

### A stale file answers confidently in the wrong layout

One round was emitted over a path whose previous copy was open in Excel. Saving from Excel put
the *old* file back, and the reader — mapping the new layout onto the old rows — reported an
empty canary, a ladder one row short, and twenty-one missing rows. Every one of those was a
layout mismatch wearing the costume of a measurement.

The file now carries its round number and the reader refuses a file it does not recognise.
Emit and read also walk one shared layout instead of two hand-kept sets of row constants, so
there is nothing left for the two halves to disagree about.

---

## What an implementation should take from this

| | |
|---|---|
| Expression nesting | bound at **65**; a violation is a *file* defect, not an evaluation error |
| Recursion | bound at **4,096**, counted in **calls** |
| The two | **separate counters** |
| The refusal | `#NUM!`, and **not** routed through anything a formula can catch |
| Iteration (`REDUCE` and kin) | not bounded with recursion; no limit to 8,192 |
| `LAMBDA` arity | **exact** — fewer arguments than parameters is `#VALUE!`, not an omission |

A single depth counter — particularly one incremented per AST node, which is neither of the
things Excel counts — cannot express any of this.

---

## Provenance

Every number here came from a workbook Excel calculated and saved. The sheet that produced
them is `Sources/ConformanceWorkbook/RecursionDepthSheet.swift`, and it is now entirely
controls: emit it against a newer Excel, read it back, and anything that moved is news.

The one thing not established is whether these numbers differ by platform or version. They
are one Excel's answers, on one machine, on one day — which is still five more measured facts
than the documentation contains.
