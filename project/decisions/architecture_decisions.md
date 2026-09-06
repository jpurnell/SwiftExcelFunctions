# Architecture Decisions

Decisions that outlive the discussion that produced them. Each records what was
decided, what it rules out, and enough of the reasoning that someone can tell
whether a later situation is the same one.

---

## ADR-001 — Excel is the specification; standards sit beside it, never instead of it

**Date:** 2026-09-05
**Category:** testing
**Status:** Accepted, in force

### Decision

Correctness for this package means **agreement with the value Excel recorded**, measured
against real workbooks.

Where Excel departs from a published standard, we match Excel under the Excel-facing name and
expose the standard beside it under a name that says which standard. We never silently pick one.

### The case that settled it

`YEARFRAC(start, end, 1)` is Excel's basis 1, documented as "actual/actual". It is **not** ISDA
ACT/ACT. For 2023-11-30 to 2024-03-31 Excel answers exactly ⅓ and ISDA answers 0.33357, because
ISDA splits the interval at 1 January and divides each piece by its own year's length while Excel
applies an averaging rule. Both are defensible. They are not the same number.

Binding basis 1 to ISDA would have made this function disagree with the spreadsheet it came from
by a third of a percent — silently, in a calculation that prices things. So BusinessMath now ships
both, and the plain name went to the spreadsheet's rule:

```swift
DayCountConvention.actualActual        // what a spreadsheet means
DayCountConvention.isdaActualActual    // what the standard means
```

Someone arriving from a spreadsheet gets the spreadsheet's rule without having to know there are
two. Someone who wants ISDA is, by definition, someone who knows to ask for it.

### What this obliges

A disagreement between us and Excel has exactly three dispositions, and choosing among them is
the work:

1. **Our bug.** Fix it.
2. **Excel doing something surprising but documented.** Match it, and record why in the
   function's doc comment — otherwise the next person "fixes" it back.
3. **Excel departing from a standard.** Match Excel under the Excel-facing name; expose the
   standard beside it, named for the standard.

Category 3 is a callout, not a correction. Making it visible is the job; deciding which is right
for a given caller is not ours.

### What it rules out

- **Silently improving on Excel.** A function that is more correct than the spreadsheet is a
  function that disagrees with the spreadsheet, which for a translation layer is a defect however
  good the mathematics.
- **Testing only against our own reading of a specification.** That is what let a day count ship
  wrong for months: BusinessMath had "only ever checked the convention against its own
  definition, never against a spreadsheet," and this package's own tests used clean dates with no
  month ends. Two implementations reasoning from one definition agree with each other and are both
  wrong.
- **Reimplementing a computation to work around an upstream defect.** Bases 0 through 3 are
  currently wrong — a day at a February month end, an hour across a daylight-saving boundary —
  and are documented as wrong rather than patched here. A second implementation of a day count is
  precisely what the package split exists to prevent.

### How it is enforced

- `ExcelOracleTests` — every formula we can evaluate, against the value Excel cached for it.
  Opt-in, because it reads private workbooks and takes minutes. **99.60%** agreement over
  155,897 comparable cells at the time of writing.
- `MicrosoftSpecificationTests` — the same rules taken from the published function reference,
  runnable in the gate on a clean checkout by someone who has never seen the corpus. The oracle
  answers "how often do we agree", which is a number you either trust or you do not; these say
  what the rule *is*. Both are needed, and the second is what makes the first inspectable.

Expected values in either suite are quoted from a published example or computed from a documented
formula and shown beside the test. None is taken from what this package currently returns.

### Where the values cannot be matched

Monte Carlo is excluded rather than compared. Risk Solver's `Psi*` family draws samples with no
published seed, so a cached value is one draw from one run — measured: of 90 corpus cells carrying
an explicit `PsiBaseCase(X)`, 71 cache the value at X and 19 cache a draw, with nothing in the
file to say which. Those bindings are judged against the published specification, which is the
only oracle that exists for them. Counting them as disagreements would hold the agreement number
down by something no work could fix, which is the fastest way to make a measurement worth
ignoring.

The same applies to volatile functions: a cached `RAND()` records what Excel drew on an afternoon
in 2013.

### Consequences accepted

- Two test suites covering overlapping ground, deliberately. They fail for different reasons and
  a defect that escapes both is rarer than one that escapes either.
- The agreement number will never reach 100%, and should not be read as a grade.
- Some functions are shipped documented-as-wrong while a fix is upstream. Stating the defect where
  a caller reads it is the obligation that makes that acceptable.
