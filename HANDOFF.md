# Handoff

**Updated:** 2026-09-18
**Branch:** `main`, pushed, clean
**State:** 591 functions · 1,736 tests · gate 45/45 uncached · zero warnings

Read this first, then `project/summaries/2026-09-17_LambdaAndTheUnreviewedBucket.md` for how
the current state was reached.

---

## Where the project is

Nothing is in progress. Nothing is blocked. The last session closed the two things that had
been open longest:

- **`LAMBDA`** — all six proposal steps, plus a prerequisite the proposal did not have.
- **The unreviewed bucket** — 87 `EXCEL` rows → **0**. Final: 473 `have`, 25 out of scope with
  a written reason each, 20 bindable, 1 new.

The three repos are in step and all pushed:

| Repo | Version |
|---|---|
| SwiftExcelFunctions | `main`, ahead of the 0.10.0 tag |
| SwiftExcelCore | **v0.12.0** |
| SwiftXLSX | **v0.29.0** |

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

### 2. The 147 `PSI` rows

Still `unreviewed`, and deliberately not touched: they need a simulation engine rather than a
classification. Tracked separately from the EXCEL bucket, which is closed.

### 3. `GROUPBY` and `PIVOTBY`

Classified **out of scope on zero demand**, not on difficulty — `LAMBDA` and the higher-order
six now supply everything they need. The reason is written down in
`project/docs/technical/LookupOutOfScope.md`, and **the classification should move the moment
one appears in a corpus.**

### 4. The sibling logging rules

`quality-gate-swift-project/plans/proposals/ACatchThatSwallows.md` §7 records that
`logging.silent-try` and `hasPrintOrNSLog` use the same substring technique that produced a
**51% false-negative rate** in `logging.catch-without-logging`. Both halves of that proposal
have landed upstream; neither sibling rule has been measured.

### 5. `ERROR.TYPE` codes 8–13

`#GETTING_DATA`, `#SPILL!`, `#CONNECT!`, `#BLOCKED!`, `#UNKNOWN!`, `#FIELD!` — unrepresentable
in `ExcelError` and therefore unmeasured. Only `#CALC!` was reachable, and its 14 is now
measured rather than published.

---

## How this project works, if you are new to it

Four practices that are load-bearing, each of which exists because ignoring it cost something:

**Measure, do not reason from documentation.** Microsoft's documentation has been wrong **six**
times here. `conformance-workbook` writes questions into a workbook, you open it in Excel and
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
