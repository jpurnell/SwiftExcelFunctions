# Agreement with Excel — the 1.0.0-alpha.1 release

**Written:** 2026-09-21
**Covers:** v0.11.0 (2026-09-18) → v1.0.0-alpha.1, 47 commits over three days.

---

## Where this ended up

**300 workbooks. 4,524,171 comparable cells. 99.999978% agreement.**

| | |
|---|---:|
| workbooks compared | 300 |
| comparable cells | 4,524,171 |
| agreed | 4,194,003 |
| agreed on an error | 330,167 |
| **differed** | **1** |
| refused | 0 |
| threw | 0 |

The one remaining cell is **not a defect**, and round sixteen is what established that. It is
`SUM('Desktop BF'!NO236, …, #REF!)` in an autosaved workbook that caches `#REF!` for the call
while caching `#VALUE!` for the cell the call reads first. Both cannot be current. Asked
directly, Excel confirms this package's rule — argument order decides which error propagates —
so the file contradicts itself and there is nothing here to fix.

Alongside that: **690 functions registered**, 1,985 tests, quality gate 45 of 45 at 0 errors
and 0 warnings, and every row of the coverage matrix classified for both the `EXCEL` and `PSI`
sources.

## How it got there

The run that opened this stretch found **402 disagreements across 10 files**. Every one is
accounted for.

| what | cells | what was actually wrong |
|---|---:|---|
| shared formulas moved pinned columns | 240 | the lexer stripped `$` from `$BE:$BE` before the parser saw it |
| `SUMIFS` array criterion | 81 | a criterion that was not a single value had no criteria string |
| `IF` array condition | 64 | `isTruthy(array)` threw `#VALUE!` |
| implicit intersection | 11 | a range in a scalar operator stayed an array |
| `VLOOKUP` blank key | 3 | a blank lookup matched the blank inside the table |
| negative base, odd root | 2 | `pow(-0.07, 0.2)` is `NaN` in C; Excel takes the real fifth root |
| stale cache | 1 | the workbook disagrees with itself |

And before that, `GETPIVOTDATA` — 3,802 cells, 90% of everything a 300-workbook run disagreed
on at the time, now **all agreeing**, with the four pivot-carrying workbooks at 100.00% across
19,880 comparable cells.

## What this stretch is actually about

Almost none of the work was writing formulas. It was **finding out what Excel does**, and the
recurring shape is that the thing standing between us and agreement was a belief nobody had
checked.

**The shared-formula defect is the clearest case.** One sheet carried 13,821 shared followers.
A master pinning `SUMIFS($BE:$BE, $AZ:$AZ, BP$2, …)` had those columns walked along with every
copy, so criteria landed on unrelated data and 120 cells read `0`. Two existing tests asserted
the broken behaviour **and passed** — they compared `$E:$E` against a column-*relative*
`CellRef`. The rule was right in `SharedFormula.shift` the whole time; it was never told.

**`GETPIVOTDATA` began from a documented decision that was the opposite of the truth.** The
note said pivot values need `xl/pivotCache/` and were therefore out of scope. They do not: a
pivot's values are rendered onto the worksheet and cached there like any other formula result,
so the function is a lookup. The old note is left standing in the source with its correction
beside it, because a decision recorded and then disproved is worth more than one quietly
rewritten.

**Every substantive claim the pivot design document made before any code existed was wrong in
some way**, and the file corrected each: pairs match whichever axis a field is on rather than
row labels; the cache *is* needed, for field names though never for records; a data field
answers to its source name as well as its caption; subtotal rows are answers rather than noise
to skip; and the 1,800/2,002 phase split was an artifact of a regex that could not parse a
nested call.

## The habit that did the work

**Measure, then build.** Where it was skipped, it cost something:

- A `SUMIFS` shape guard generalised past its measurement refused 15 cells Excel answers.
- Criteria error propagation measured at one argument position and applied to all cost 672.
- A phase split taken from a regex rather than a parser misstated the remaining work by 4×.
- I described implicit intersection's blast radius as "every comparison in every normally
  entered formula" and it is **100 formulas in 2,588,513** — 88 of them already protected. I
  was wrong by two orders of magnitude, in the safe direction, and the measurement that settled
  it took ten minutes.

Where it was followed, it settled things reasoning could not. **Implicit intersection was the
riskiest change here**, because its failure mode is silently wrong numbers rather than errors:
intersection firing inside an array-expecting slot returns a plausible value. The corpus was
the arbiter rather than the argument — `agreed` rose by exactly 11, `agreedOnError` and
`notComparable` unchanged to the cell. Nothing else moved.

## Round sixteen

Sixteen conformance rounds now; 324 cases. The last one asked the four things this stretch
decided without asking.

| question | answer |
|---|---|
| which error wins between an argument's `#VALUE!` and a literal `#REF!` | **order decides** — we were right |
| does an odd root of a negative base have a real value | **yes**, and `(2/3)` does not — the guess held |
| what is a blank lookup value | **`0`** — we were wrong |
| do two array criteria broadcast or pair | **pair, elementwise** — we were wrong to keep refusing |
| does intersection reach a function argument | **yes** — a gap, left open deliberately |

The blank-lookup answer is the one worth keeping. The corpus cells still come out `#N/A`,
because their keys are names and `0` matches no text — so the first fix **agreed with every
piece of evidence and was wrong about the mechanism**. It would have failed on the first
numeric key it met. A rule that is right about the evidence and wrong about the why survives
exactly until the next workbook.

**Emitting the round found three harness defects, one of which would have manufactured
findings.** `CaseCells` keyed by `CellRef.reference`, which renders the `$` markers, so a case
writing data to `H317` and asking about `$H317` read a blank. Its *control* row — a lookup
whose key is plainly in the table — came back `#N/A`. The real questions beside it would have
been answered against empty cells and read as divergences. Controls are cheap and they are
what caught it.

## What is deliberately not done

- **Implicit intersection at a scalar function argument.** Excel does it; this does not.
  Closing it needs every function to declare which arguments take a value and which take a
  range, a per-argument fact about several hundred functions, and 4,524,171 comparable cells
  contain no case that turns on it. Recorded as a known divergence with the reasoning.
- **Two array criteria of different lengths.** Excel broadcasts by orientation; nothing has
  asked it what shape comes back.
- **`forcesArrayArguments` marks only `SUMPRODUCT`.** Empirically sufficient — the corpus moved
  not one cell when intersection shipped — and extending it without measurement is the trade
  this stretch repeatedly learned to refuse.

## Why alpha

The library agrees with Excel on essentially everything measurable and the API has been stable
through this whole stretch. What is not yet proven is the **shape of the public surface under a
real consumer**. The simulation GUI is the first thing that will exercise it as a client rather
than as a test harness, and a pre-1.0 identifier says plainly that the surface may still move
for it.

Two things worth knowing before depending on this:

- **SwiftPM range requirements do not match pre-release versions.** `from: "1.0.0"` will not
  resolve `1.0.0-alpha.1`; a consumer must pin it exactly.
- **The dependencies are still 0.x** — SwiftExcelCore 0.19.0 and SwiftXLSX 0.36.0 — and both
  ship breaking changes in minor versions by their own stated policy. A 1.0 on top of that is
  a statement about *this* package's surface, not about the stack beneath it.

## Next

The simulation GUI: driving `Psi*` functions in otherwise standard models. The evaluator
already carries what it needs — `RandomSource`, `SimulationResultProvider`, and every
distribution the corpus calls — and this release is the point at which the formula layer stops
being the thing under construction.
