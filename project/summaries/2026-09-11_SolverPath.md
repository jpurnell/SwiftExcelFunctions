# Session Summary: the Solver path, and what real files taught

| Date | Phase | Status |
| :--- | :--- | :--- |
| 2026-09-11 | Solver (beyond master plan priority 4) | `v0.9.0` shipped; `0.9.1` pending a doc pass |

## 1. State at handoff

- **1,251 tests**, 9 skipped, 0 failures. **Gate 45/45 at zero warnings.**
- **`v0.9.0` tagged and pushed.** Two commits sit **unpushed** on `main`:
  - `85ee6ec` — the numeric-parse fix, the entry point, the census tool (mine)
  - `d87b9c1` — AGPLv3 licensing (**another session's**; do not fold into a release commit)
- Working tree also carries that session's `README.md` edit. **Commit with explicit paths.**
- Upstream released today: **SwiftXLSX `v0.23.2`, `v0.24.0`, `v0.24.1`; SwiftExcelCore `v0.8.0`.**

## 2. What shipped

An Excel Solver model now **reads and solves**, end to end:

| Piece | What it is |
|---|---|
| `SpreadsheetFunction` | a sheet as `([Double]) -> [Double]` — set, recalculate, read |
| `ExcelSolverReader` | the model from `solver_*` **defined names** |
| `SolverRun` | the join, plus `solve(cells:names:inSheet:)` as the one-call entry |
| `workbook-census` | an executable that scans a corpus for Solver models |

**The engine is dispatched, not obeyed.** `SolverModel.engine` records what the workbook
asked for; `Solution.engineUsed` reports what ran. A model declared for Excel's plain
Simplex can go to branch-and-cut. All three engines dispatch for real: Simplex probes the
sheet for linear coefficients and **refuses a nonlinear model** (Excel's own answer),
evolutionary refuses an unbounded variable (likewise), integrality goes to branch-and-bound
and **outranks** the nominated engine.

## 3. Immediate next step

**The doc pass for `0.9.1`**, then tag. CHANGELOG entry + link reference, `master_plan`
Current Status and Last Updated, README status line — **coordinate the README with the
licensing session**, which is editing it now.

Then: **the census re-run is in flight** (see §6). Its earlier 167 rows have **stale
`engines` and `relations` columns**, written before the parse fix. `solver_names` and
`models` in those rows are still valid.

## 4. What real files taught, and what each would have cost

Three workbooks Justin built in Excel, plus one corpus scan, produced more correction than
every test written for this feature.

| Found | Would have been |
|---|---|
| **Numbers arrive as text.** `solver_eng = 2` is not a reference, so it resolves to `.formula(.text("2"))` | every model read as GRG, and **every model read as having no constraints** — solving unconstrained versions of real problems |
| Models are **sheet-scoped** (`localSheetId`) | two sheets' models merged into one made of neither's parts |
| `solver_num` is authoritative *(observed)* | five deleted constraints resurrected, including an `alldifferent` |
| `solver_opt` is **absent**, not empty, with no objective | a legal Excel model refused |
| `solver_typ` is written anyway | `.maximise` reported for something that maximises nothing |
| `solver_lin` exists (pre-2010 linearity flag) | an old linear model solved by a nonlinear method |
| An integrality bound is a **word** | read as an empty cell list, by accident |

**All encodings are now measured**, not documented: six relation codes, three engines, both
`solver_neg` settings, `solver_typ` for Max and Value Of. Only `solver_typ = 2` for Min is
inferred, as the last of three.

## 5. Context-loss warnings

1. **Hand-built fixtures agreed with the code about things neither had checked — three
   times this week.** The corpus provenance, the furigana corruption, and the numeric
   parse. Tests that construct a `NamedRangeTarget` by hand encode an assumption about
   parsing rather than exercising it. `ExcelSolverReaderParseTests` uses the *textual* form
   deliberately; keep it that way.
2. **A penalty makes a hard constraint soft.** NelderMead penalises everything it is given,
   `.linearInequality` included — only branch-and-bound's relaxation and simplex enforce
   exactly. Bounds are therefore clamped *inside* the objective and all-different is decoded
   from sort keys into a permutation, so no infeasible point exists to be found. **Projecting
   the answer afterwards moves infeasibility rather than removing it** — clamping a variable
   an equality ties to another breaks the equality.
3. **The logging checker is syntactic.** It wants `Logger(...).error(...)` *literally inside*
   the catch. A delegating helper does not satisfy it — learned twice in one session, in
   `SpreadsheetFunction` and again in `WorkbookCensus`.
4. **`positionKey` is `absolute()`.** Storage keyed relatively and looked up absolutely finds
   nothing — and a provider returning `nil` for every cell yields an *empty evaluation order*
   rather than an error. Conversely `populatedCells()` must return the **relative** form, or
   `DependencyGraph` sees `$B$1` and a formula's `B1` as two cells and a cycle through them
   reports acyclic.
5. **Never schedule background work on this machine.** A polling loop that armed itself and
   started reading `~/Documents` was unwelcome. Heavy sweeps run in the foreground, when
   asked. See `feedback-no-background-polling`.
6. **Two `swift test` runs share one `.build` lock.** The second does not run slowly — it
   does not run at all, while appearing to.

## 6. The census

`swift run workbook-census <root> --out census.tsv` — incremental, resumable, and **useful
when partial**, which the two abandoned `XCTestCase` versions were not.

First partial run, 167 of 2,240 workbooks: **18 carry Solver models, 40 models in all**, one
workbook with **seven** (one per sheet). Zero unreadable, which is the `v0.24.1` lexer fix
holding. So Solver models are *real* in this corpus — unlike `FORECAST.ETS*` and the `IM*`
family, both measured at zero.

**The output file is the resume state**; a re-run skips what it already holds. The current
re-run was started from a *fresh* file, because the old rows' engine and relation columns
predate the parse fix.

---

**Next action:** the `0.9.1` doc pass, then read the census when it lands.
