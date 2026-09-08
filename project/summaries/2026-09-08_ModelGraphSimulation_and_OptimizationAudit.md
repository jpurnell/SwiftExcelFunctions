# Session Summary: The model graph, and the optimization audit

| Date | Phase | Status |
| :--- | :--- | :--- |
| 2026-09-07 → 2026-09-08 | Phase 0 (Design) — two proposals | COMPLETED (design only; no implementation here) |

**This was a design and audit session, not a TDD implementation session.** No production code
was written in this repository. The one code change made anywhere lives in BusinessMath and was
committed there by a peer session (§7).

---

## 1. Core Objective

The session opened with a feasibility question, not a task: *given full coverage of the Excel
math library and the Risk Solver PSI family, could we ship a Microsoft Excel for Mac plugin that
replicates Solver?*

Answering it honestly required auditing what we actually have, and the audit changed the answer
twice. The output is two design proposals and a corrected roadmap.

---

## 2. Design Decisions

### D1 — The lowering pass is an optimization, not a requirement

- **Decision:** Ship two evaluation paths. An **interpreted** trial loop (mutate a
  `CellValueProvider`, re-run `FormulaEvaluator` in topological order, once per trial) that
  handles every formula the registry can already evaluate, and a **compiled** path that lowers
  `FormulaAST` to BusinessMath's `Expression` bytecode and handles a subset, fast.
- **Rationale:** They are not alternatives. They are a correctness baseline and a fast path that
  must produce **bit-identical** trial vectors under the same seed. That single constraint is
  simultaneously the fallback strategy and the strongest test in the suite. A model that will not
  lower still runs — slowly, and says so.
- **Consequence:** shipping is gated on *lowering the first workbook*, not on lowering
  completeness. Phase 3 ships a working product; Phase 4 makes it fast.
- **Alternatives rejected:** lower-everything-or-refuse (makes shipping conditional on a
  completeness that §5.2 of the proposal proves unreachable — `OFFSET`/`INDIRECT` can never lower).

### D2 — `SimulationResultProvider`, mirroring `CellValueProvider`

- **Decision:** `PsiMean(B4)` reaches a completed run through a caller-supplied protocol, exactly
  as cell values already reach the evaluator.
- **Rationale:** `B4` has ten thousand values; it cannot be a function of `B4`'s *value*. This
  package already had the idiom for "the caller supplies the world," so the seam was named rather
  than invented. Evaluation becomes two passes, which is also how the real product behaves —
  statistics read `#N/A` before a run completes.

### D3 — Refuse rather than approximate on type mismatch

- **Decision:** a model whose trial path can produce text or an Excel error does not lower; it
  interprets. `LoweringFailure` names the cell.
- **Rationale:** `Expression` is `Double`-only, so `1/0` lowers to `+inf`, not `#DIV/0!`. A NaN
  propagating into a mean is a plausible wrong number, which `master_plan.md` §7 names as the
  failure this project exists to prevent.

### D4 — LibreOffice is a better host than Excel

- **Decision:** SwiftUI app first and unconditionally; LibreOffice second; Excel last or never.
- **Rationale:** verified, not assumed. `XAddIn` registers functions under **real names** (no
  forced `NAMESPACE.` prefix), a UNO component is **long-lived** so it can own a completed run and
  answer `PsiMean` — which a stateless Office.js custom function structurally cannot — and
  `com.sun.star.sheet.XSolver` is a **documented pluggable optimizer socket** that lp_solve,
  CoinMP and DEPS already register against in module `sccomp`.

### D5 — GRG is a correctness requirement, not a marketing item

- **Decision:** move GRG from Tier 3 position 6 to position 2 in BusinessMath's roadmap.
- **Rationale:** the January roadmap called it *"functionally redundant with SQP."* True
  mathematically. But this project treats Excel as the specification (ADR-001), and a workbook
  that ran Excel Solver recorded **GRG2's** answer. On a nonconvex problem SQP and GRG converge to
  different local optima, both valid, neither reproducing the other. GRG is therefore the only
  algorithm in that set testable against the oracle corpus.
- **Falsifier recorded:** before writing GRG, run both on corpus Solver models and count
  disagreements. If SQP reproduces Excel's answers, this argument is wrong and GRG returns to
  Tier 3 — written into the proposal so it cannot be quietly dropped.

---

## 3. Work Completed

### Design Proposals (Phase 0)

- [x] **`project/plans/proposals/PROPOSAL_model_graph_simulation.md`** (this repo, 16 sections) —
      graph → lowering → simulation → read-out, the four hard edges, API with Swift signatures,
      error handling, test strategy, performance, SwiftUI front end, host analysis, phasing.
- [x] **`BusinessMath/project/plans/proposals/PROPOSAL_advanced_optimization_gap.md`** —
      the verified audit, two housekeeping corrections, re-prioritisation, shared contracts.

### Audit (the part that changed the answer)

- [x] **Reversed an incorrect claim.** I first scoped the optimization engines as work to be
      built, inferring from `excel_function_coverage_matrix.tsv`'s `provider` column — which
      records whether a *Psi function has a binding* and says nothing about BusinessMath's
      contents. Reading the checkout showed Simplex (with `dualValues`/`reducedCosts`),
      branch-and-bound, the full nonlinear and heuristic stacks, `MonteCarloSimulation`, Sobol /
      Halton / Owen-scramble sampling, and — decisively — `MonteCarlo/Compilation/`
      (`BytecodeCompiler`, `MonteCarloExpressionModel`). The PSI-interpreter architecture was
      already there.
- [x] **Verified all 9 roadmap phases** with `git log --all --oneline -S"<id>" -- Sources/`,
      which answers "was this ever written and then lost" rather than "is it here now."
      Result: **zero commits ever, on any branch**, for SQP, InteriorPoint, ADMM, GRG,
      NetworkFlow, Hungarian, Bellman, McCormick.
- [x] **Found MINLP already shipping.** `BranchAndBoundSolver` takes a pluggable
      `relaxationSolver`, and `NonlinearRelaxationSolver` already conforms. The roadmap said
      "Not Started" for eight months.
- [x] **Found the root cause of the drift.** Both relaxation files entered in commit `fb626e3a`,
      message: *"Package Fix Attempt 1 for CI"*. A capability shipped inside a chore commit, so
      nothing downstream was prompted to notice.

### Cross-repo work (BusinessMath — see §7)

- [x] `Roadmap.md` reconciled (+310/−69) — Phase 3 marked Done-with-caveat, the verification
      method recorded so nobody repeats the audit, revised order applied with January's reasoning
      struck through but left readable, deferrals recorded.
- [x] `NonsmoothOptimization.md` moved to `completed/` (had shipped in `f1e70490`).
- [x] `BranchAndBoundSolver+MINLP.swift` — a `.minlp()` discoverability alias, strict TDD, DocC,
      quality gate 0/0 across 45 checkers, full suite **7,279 tests in 647 suites passed**.

### Not done

- [ ] No implementation in this repository. `ModelGraph`, `Lowerer`, `WorkbookSimulator` and
      `SimulationResultProvider` exist only as proposed signatures.
- [ ] Phase 0 spike not started.

---

## 4. Mandatory Quality Gate

```
$ quality-gate
==========================================
✅ Quality Gate: PASSED
   45 of 45 checkers
==========================================
[exited with code 0]
```

| Check | Status |
| :--- | :--- |
| **all 45 checkers** | ✅ |
| **duplication** | ✅ (5 informational clone notes, all pre-existing) |
| **consistency** | ✅ (institutional score 1.00, threshold 0.70) |

Run at session end on `556fc79` + documentation. No check failed.

*Note:* the run was captured with `| tail -30`, so per-checker lines above `duplication` scrolled
out of the log. The summary line and exit code are the observed facts; the individual test count
was not captured and is not claimed here.

No production code changed in this repository this session, so the gate result reflects the
tree as it stood at `556fc79` plus documentation.

---

## 5. Project State Updates

- [x] `project/checklists/CURRENT_*.md`: **none exist** — nothing to update.
- [x] `project/master_plan.md`: **not updated, deliberately.** The simulation work is a proposal,
      not an accepted architecture. It belongs in the master plan when Phase 0 answers whether
      the fast path is worth having. Flagged rather than skipped.
- [x] `project/plans/proposals/PROPOSAL_model_graph_simulation.md`: created.

---

## 6. Next Session Handover

### Immediate Starting Point

**Phase 0 of `PROPOSAL_model_graph_simulation.md` §12 — the spike.** One hand-built `ModelGraph`
for a single arithmetic model, lowered to `MonteCarloExpressionModel`, 10,000 trials, print the
mean. It requires no `.xlsx` reading, no recognizer and no UI.

**Its purpose is one measurement: the interpreted-to-compiled ratio.** If it is 50×, the fast
path is a nicety and lowering can wait. If it is 5,000×, lowering coverage *is* the product and
Phase 4 moves ahead of the SwiftUI work. Everything after Phase 0 is ordered by that number and
by the Phase 2 corpus histogram.

### Pending Tasks

- [ ] Phase 0 spike; record the ratio.
- [ ] Phase 1 — `ModelGraph` + builder + cycle detection.
- [ ] Phase 2 — `Lowerer.audit` across the 41 Risk Solver workbooks. **This produces the coverage
      number that actually gates the work**, and it is *not* the number the matrix tracks: the
      matrix asks "can the registry answer this function?", the audit asks "can this function
      survive a trial loop?" A function can be `have` and still be unlowerable.
- [ ] Decide open question §15.4 (multi-output sharing) — currently eight outputs means eight
      compilations.

### Blockers

- **None blocking.** One coordination item: BusinessMath was mid-release (v2.15.0) at session end
  and a peer session asked us to hold commits in that tree until it tags and pushes. That hold
  applies to BusinessMath only; this repository is unaffected.

### Context Loss Warning

1. **Do not re-derive "the engines need building."** They exist. The mistake was reading the
   coverage matrix's `provider` column as a statement about BusinessMath's contents; it is a
   statement about Psi bindings only. §2 of the simulation proposal records this.
2. **`Expression` has a ternary.** `IF` lowers directly to `.conditional`. `SUM` →
   `ExpressionArray.sum()`, `SUMPRODUCT` → `.dot(_:)`. The mapping is far closer than expected —
   do not assume a big translation layer before reading §4.
3. **`BytecodeOptimizer` does constant folding and algebraic simplification but NOT CSE.** Graph
   inlining without CSE could blow up node count on fan-out. Measure in Phase 2 before mitigating;
   if it bites, the fix belongs upstream where every caller benefits.
4. **The two-path design is load-bearing, not belt-and-braces.** Removing the interpreted path to
   "simplify" would delete both the fallback and the differential test that validates every
   lowering rule.
5. **The type in BusinessMath is `BranchAndBoundSolver<V>`, not `BranchAndBound`.** Both proposals
   originally had this wrong; corrected.
6. **`.minlp()`'s cut-generation parameters are inert.** `BranchAndBound.swift:958` gates cuts on
   `RelaxationResult.simplexResult`, which `NonlinearRelaxationSolver` never supplies. Recorded as
   open question §10.4 of the optimization proposal with a recommendation to trim.

---

## 7. Cross-Repo and Cross-Session Notes

Work reached into **BusinessMath**
(`/Users/jpurnell/Dropbox/Computer/Development/Swift/Playgrounds/Math/BusinessMath`), where a peer
Claude session was live in the same working tree. Two things resulted that are worth carrying
forward:

- **A bare `git commit` builds from the whole shared index.** The peer's commit `affa6c91` swept
  up our staged `NonsmoothOptimization.md` rename under an unrelated message. Nothing lost;
  history misattributes the change. **Use `git commit -- <explicit paths>` in shared repos**, and
  re-check `git status` immediately before committing rather than once at the start — our tree
  snapshot went stale within minutes.
- **The peer improved our test and found a real bug.** Our MINLP fixture's continuous optimum was
  (2,2) — already integral — so branch-and-bound terminated at the root and the suite never
  exercised branching. It added a `nodesExplored > 1` case. Chasing why runtime scaled with
  `nlpMaxIterations` while the answer did not move, it then found `InequalityOptimizer` burning
  its full 100 outer iterations on infeasible nodes (ρ saturates near step 16) and added a
  stopping rule. **Its near-miss is the durable lesson:** testing the stall on
  `max(violation, stationarity, complementarity)` let a stalled stationarity hide a still-falling
  violation, stopping at 2.8e-6 and flipping a feasible node to `.infeasible` — silently pruning
  a live subtree. The verdict is `violation ≤ tolerance`, so the stall test must watch the
  violation alone.

---

**Session Duration:** ~2 sessions across 2026-09-07 and 2026-09-08
**AI Model Used:** Claude Opus 5 (1M context)
