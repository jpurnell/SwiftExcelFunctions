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

---

## ADR-002 — The byte functions are Western-locale, and say so

**Date:** 2026-09-09
**Category:** scope
**Status:** Accepted, in force

### Decision

`LENB`, `LEFTB`, `RIGHTB`, `MIDB`, `FINDB`, `SEARCHB` and `REPLACEB` behave as they do
under a **single-byte locale**: identically to `LEN`, `LEFT`, `RIGHT`, `MID`, `FIND`,
`SEARCH` and `REPLACE`.

No locale is modelled. The package gains no locale parameter, and
``EvaluationContext`` gains no field.

### Why this is a decision and not an omission

ADR-001 says Excel is the specification. These seven functions are the case it does
not cover: **Excel's answer depends on the machine it is running on.**

Under a DBCS locale — Japanese, Chinese, Korean — a double-byte character counts as
two, so `LENB("あい")` is 4. Under any Western locale it counts as one and the answer
is 2. Same workbook, same formula, two answers, and *nothing in the file records
which locale produced the cached value*. There is no single Excel to match.

So a choice had to be made rather than discovered, which is what makes it an ADR.

### Why Western

- **Nothing in the corpus calls them.** All seven measure zero calls across 2,240
  workbooks, as do `DBCS`, `JIS`, `PHONETIC` and `BAHTTEXT`. This is completeness
  work, and completeness work does not justify a public API change.
- **The alternative is a locale seam.** Modelling this properly means an optional
  locale on ``EvaluationContext``, in the shape `random` and `simulation` already
  have — a public API change, a default to argue about, and a second code path
  through seven functions, for a behaviour no measured workbook exercises.
- **Western is the honest default for a package with no locale.** Returning DBCS
  answers on a machine with no DBCS locale would be *less* faithful to what Excel
  does in front of the person running it, not more.

### What this rules out

- **Claiming DBCS support.** These are documented as Western-locale, in each
  function's own DocC, so a caller reads the limit where they read the function.
- **Quietly diverging later.** If DBCS behaviour is ever wanted, it arrives as a
  locale on the context and these become two-branch functions. That is an additive
  change and this decision does not block it — the seam is *open*, merely not built.

### The revisit condition, stated so it is testable

A workbook that calls any of the seven, from a DBCS locale, where the cached value
disagrees with the Western answer. That single measurement flips this decision, and
until it exists the locale seam is speculative work.

### Related, and deliberately not bundled

- **`PHONETIC` is blocked upstream, not undone.** It reads furigana stored as `<rPh>`
  runs in the file, and SwiftXLSX does not parse them. It is a file-format read
  wearing the shape of a text function, and it belongs to whoever adds `rPh` support.
- **`DBCS` and `JIS`** convert between half-width and full-width forms. That is a
  Unicode mapping table rather than a locale question, and it is unaffected by this
  decision.

---

## ADR-003 — Excel's zero-snap is reproduced; Excel's 15-digit storage is not

**Date:** 2026-09-14
**Category:** numerics
**Status:** Accepted, in force

### Decision

Two Excel behaviours were measured in the same round. One is implemented and one is not.

**Implemented — the final-operation snap.** A result that is negligible against its own
operands becomes exactly zero: on the last addition or subtraction of a formula, and on
every comparison wherever it sits. `0.1+0.2-0.3` is `0`; `IF(0.1+0.2=0.3,…)` says equal.
See ``ExcelFinalRounding``, whose threshold and scope were read out of Excel rather than
out of documentation.

**Not implemented — the 15-significant-digit store.** Excel keeps 15 significant decimal
digits, so `0.9999999999999985` is `0.999999999999998` before any arithmetic runs. We keep
the full `Double`.

### Why the line falls there

The snap is Excel **computing differently**. No amount of correct arithmetic produces
`0.1+0.2-0.3 = 0`; Excel applies a rule, and a package that claims agreement with Excel has
to apply the same rule or disagree with every cancelling subtraction in every workbook.

The digit limit is Excel **computing worse**. It discards information that was correctly
computed. ADR-001 obliges us to match Excel's *values*, and this is the case already
settled twice against reproduction — the Bessel family, where Excel is wrong by up to
1.6e-7 and we match scipy to 1e-15, and `IMSQRT`, where Excel's own `i²` is not `-1`.
Implementing the digit limit would move us *away* from those decisions, not toward
consistency with them.

### What this costs, stated plainly

Cells whose cached value was shaped by the 15-digit store will disagree with us in the
16th digit. That disagreement is real and will show up in the oracle. It is accepted.

### The revisit condition

A corpus cell where the 15-digit store changes an answer **visibly** — a different integer,
a different branch of an `IF`, a different rank — rather than a trailing digit. That is a
different problem from precision loss and would deserve its own decision.

### What it rules out

- **A global "Excel precision" mode.** Rounding every intermediate to 15 digits would make
  the package's answers worse everywhere to fix the 16th digit somewhere.
- **Reading the snap as a tolerance.** It is not an epsilon comparison bolted onto `==`;
  it is scoped — last operation only for arithmetic, always for comparisons — and that
  scope is what the measurements established. `(0.1+0.2-0.3)*1` keeps its residue.
