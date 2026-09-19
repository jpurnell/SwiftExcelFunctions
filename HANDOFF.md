# Handoff

**Updated:** 2026-09-19
**Branch:** `main`, pushed, clean
**State:** 1,779 tests · gate 45/45 uncached · zero warnings

Read this first, then `project/summaries/2026-09-17_LambdaAndTheUnreviewedBucket.md` for how
the state before this session was reached.

---

## Where the project is

Nothing is in progress. Nothing is blocked.

**Round nine of the conformance workbook returned zero disagreements across all 158 cases** —
the first clean round in this project's life. Every density boundary is measured; none rests
on an inference.

The last session ran across four repos. All are pushed:

| Repo | Version | What moved |
|---|---|---|
| SwiftExcelFunctions | `main`, ahead of the 0.11.0 tag | densities rebound, `ROWS`/`COLUMNS`, `check` |
| SwiftExcelCore | **v0.14.0** | `FormulaAST.arrayConstant`; whole spans |
| SwiftXLSX | **v0.31.1** | `1:1` parses; array constants; whole-span reader |
| **BusinessMath** | **v3.0.0-alpha.7** | `pdf(_:)` on `ContinuousDistribution`, 46 conformers |

**BusinessMath is a dependency of this package and was not previously tracked here.** It is
pinned by `.upToNextMinor(from: "3.0.0-alpha.3")`, which already admits alpha.7 — a bump needs
no `Package.swift` edit, only `swift package update`.

**`main` is ahead of the last release tag and has not been versioned.** Numbers here are
assigned at release rather than reserved, so the next release decides its own. A release would
need the doc-housekeeping pass in `CLAUDE.md` run against the `[Unreleased]` CHANGELOG section,
which is already written.

---

## What to pick up, in rough order of value

### 1. The evaluator's stack ceiling

**The most consequential open item.** Recursion reaches about **160 levels** where Excel
reaches **4,096**.

`evaluateNode` recurses, a `LAMBDA` invocation costs roughly 3.2 nodes, and `maxNodeDepth`
(512) is reached long before `maxRecursionDepth` (4,096). Both bounds are correct and measured;
the gap is the recursive design, not a wrong constant.

**A larger constant is exactly what does not fix it.** 512 was measured against the stack by
bisection — a debug build under XCTest survives ~1,100 frames and dies by 1,200 — and past it a
refusal becomes `SIGSEGV`. The fix is an explicit stack or a trampoline in `evaluateNode`,
which is a rewrite of the evaluator's core. The cheap workaround, available to any caller
today, is to run the evaluation on a thread with a larger stack.

Documented on `FormulaEvaluator.maxRecursionDepth` and pinned by
`NamedLambdaTests.testTooDeepIsRefusedRatherThanCrashing`.

### 2. Two parser gaps, both found from the side — **both now closed**

Neither blocks anything; both are real and cheap to check.

- ~~**`CellRange("A:A")` does not understand whole-column shorthand.**~~ **Closed
  2026-09-19**, and it was larger than it looked: whole-*row* forms produced references in
  column **zero**, `CellRange("")` trapped, and a descending span trapped in `cells`. The rule
  had two implementations and only SwiftXLSX's `DefinedNameResolver` had it right — which is
  why whole-column defined names round-tripped across 161,901 of them while `CellRange(_:)`
  answered `A1`, and why nobody found it. SwiftExcelCore 0.14.0, SwiftXLSX 0.31.1.
- ~~**Array literals — `{1,2,3;4,5,6}` — do not parse at all.**~~ **Closed 2026-09-19.**
  `FormulaAST.arrayConstant` (SwiftExcelCore 0.13.0), parsing and serializing (SwiftXLSX
  0.31.0), evaluation here. The lexer had no `{`, `}` or `;` token, so the gap read as a
  decision nobody had got to rather than as something simply absent.

### 3. ~~The 147 `PSI` rows~~ — **closed 2026-09-19**

**Every row in the coverage matrix is now classified**, EXCEL and PSI alike. `PSI` reads
**189 have · 71 out of scope · 17 bindable · 17 not ours · 1 new**, and
`UnreviewedCoverageTests` no longer filters to `EXCEL` — it watches the whole file, so either
bucket refilling now fails the suite.

They did **not** need a simulation engine. `SimulationResultProvider` and
`SimulationResults.values` had been there since the first seven statistics landed; what was
missing was arithmetic. Two things that were not visible from the matrix:

- **The property functions were failing whole cells.** `PsiTruncate` and the rest were
  unregistered, and an unregistered name fails the *enclosing* call — so
  `PsiNormal(10, 2, PsiTruncate(5, 15))` produced no number at all.
- **`PsiTheo*` needed no second registry of distributions.** Evaluating a cell's own formula
  with a random source that returns `p` yields `q(p)`, so the theoretical statistics read the
  sampler's own path and cannot disagree with it — and every `*Alt` percentile-parameterised
  form is covered without being named.

**17 bindable is the honest remainder.** Classified is not implemented: 13 predate this work,
and 4 are the forecasting family whose mathematics BusinessMath already has
(`PsiForecastMovingAvg`, `PsiForecastExp`, `PsiForecastDoubleExp`, `PsiForecastLinear`).

**One upstream branch is open.** `PsiKendallTau` is out of scope because BusinessMath had no
tau-b — `kendallW` is a different statistic. It now does, on `origin/kendall-tau-b`, one
commit off `main`; the BusinessMath session has been asked to merge it. Once tagged,
`PsiKendallTau` becomes a one-line binding here.

### 4. `GROUPBY` and `PIVOTBY`

Classified **out of scope on zero demand**, not on difficulty — `LAMBDA` and the higher-order
six now supply everything they need. The reason is written down in
`project/docs/technical/LookupOutOfScope.md`, and **the classification should move the moment
one appears in a corpus.**

### 5. The sibling logging rules

`quality-gate-swift-project/plans/proposals/ACatchThatSwallows.md` §7 records that
`logging.silent-try` and `hasPrintOrNSLog` use the same substring technique that produced a
**51% false-negative rate** in `logging.catch-without-logging`. Both halves of that proposal
have landed upstream; neither sibling rule has been measured.

### 6. `ERROR.TYPE` codes 8–13

`#GETTING_DATA`, `#SPILL!`, `#CONNECT!`, `#BLOCKED!`, `#UNKNOWN!`, `#FIELD!` — unrepresentable
in `ExcelError` and therefore unmeasured. Only `#CALC!` was reachable, and its 14 is now
measured rather than published.

---

## How this project works, if you are new to it

Four practices that are load-bearing, each of which exists because ignoring it cost something:

**Measure, do not reason from documentation.** Microsoft's documentation — or this project's
reasoning about it — has been wrong **seven** times here. The seventh was inference between two
Excel functions: `GAMMA.DIST` and `WEIBULL.DIST` face the identical density boundary and
answer it differently, so a convention measured on one says nothing about its neighbour.

**A disagreement dismissed as a harness artifact is a disagreement.** `ROWS(A:A)` and
`COLUMNS(1:1)` sat in the conformance output for seven rounds, explained away as consequences
of evaluating against `NoCells()`. Both were real: `ROWS(A:A)` answered the used range's height
on a fully populated sheet, and `COLUMNS(1:1)` could not be parsed at all, so the question was
never put to Excel. One probe each. `conformance-workbook` writes questions into a workbook, you open it in Excel and
save, and `depth-read` reads the answers back. Seven rounds so far, recorded in
`project/docs/technical/ExcelEvaluationLimits.md`. Round 6 reversed a decision the evaluator
had been built on.

**Every question that has been answered stays in the sheet as a control.** A round that goes
wrong then says so instead of looking like news.

**A corpus tool streams its output and resumes.** Three separate runs in this project's life
were killed after producing nothing, because they printed at the end. `name-round-trip` writes
a row per workbook, flushed, and the file is its own resume state.

**A fixture that encodes a temporary gap will rot.** Six times now. `StaleValueChecker` used
`FILTER` as its example of "a formula we cannot evaluate" until `FILTER` was implemented; it
now uses `RTD`, which is refused *by design* rather than by backlog.

Run `quality-gate --no-cache` before believing a clean gate — the cached form replays a build
that did not run, and reported clean while four warnings existed.

---

## Local state that is not on any remote

Two references in the **SwiftXLSX** clone at
`~/Dropbox/Computer/Development/Swift/SwiftXLSX`, created when it was updated onto the rebuilt
remote:

| Reference | What it holds |
|---|---|
| `pre-rebuild-history-2026-09-12` (tag) | the original 70-commit history, from "Initial release" onward |
| `pre-rebuild-local` (branch) | two uncommitted config edits carried off it |

The remote's history was deliberately rebuilt on 2026-09-12 (`d54ca9b`), orphaning the old
line. **The content was byte-identical** — nothing in `Sources` or `Tests` was ever at risk —
but that tag is the only surviving copy of the original commit messages. Delete either
reference freely; neither was pushed, because publishing an orphan history is not a decision to
make on someone's behalf.

**One live finding from that branch.** `.quality-gate.yml` there sets

```yaml
corpusPath: ${ORG_JUDGEMENT_CORPUS:-}
```

YAML does not expand environment variables, so the gate reads that literally and writes
telemetry into a directory *named* `${ORG_JUDGEMENT_CORPUS:-}`. That is where the stray
directory of that name comes from. The intent — no absolute path in the repo — is right and the
mechanism does not exist; it needs gate support or another way to supply the path.
