# Proposal — The model graph: running a Risk Solver workbook without Risk Solver

**Status:** Draft
**Spans:** SwiftExcelFunctions (the graph, the lowering pass, the statistic bindings),
BusinessMath (the engines, unchanged), a new SwiftUI application target
**Date:** 2026-09-07

`PROPOSAL_psi_bindings.md` broke the dependency on Frontline's add-in for *reading* a workbook:
a `Psi*` call answers instead of returning `#NAME?`. This proposal is the other half — **running**
one. Draw the uncertain inputs ten thousand times, propagate through the workbook's own formulas,
and answer `PsiMean(B4)` with a number that came from a completed run rather than from a cached
draw nobody can reproduce.

---

## 1. Objective

**Objective:** Take a workbook that used Risk Solver, build a graph from it, simulate it, and read
the results back — with no Excel, no add-in, and no Frontline license anywhere in the loop.

Then put a SwiftUI front end on it, because a simulation nobody can look at is a test fixture.

---

## 2. What this proposal assumed wrongly, and the correction

The first pass at scoping this assumed the engines were the work: Simplex, GRG, a Monte Carlo
driver, correlated sampling, all to be built. That was wrong, and it was wrong for a specific
reason worth recording — it was inferred from `project/plans/proposals/Excel conformance/excel_function_coverage_matrix.tsv`, whose
`provider` column records whether a **Psi function has a binding**. It says nothing about what
BusinessMath contains. Reading the checkout says otherwise:

| Capability | Where it already lives in BusinessMath 2.14.0 |
|---|---|
| Simplex LP | `Optimization/LinearProgramming/SimplexSolver.swift` (48K), async variant |
| Duals, reduced costs | `SimplexResult.dualValues`, `.reducedCosts` |
| Integer / binary | `IntegerProgramming/BranchAndBound.swift` (101K), branch-and-cut, cutting planes |
| Nonlinear | LBFGS, Newton-Raphson, conjugate gradient, `ConstrainedOptimizer`, `InequalityOptimizer`, `MultiStartOptimizer` |
| Evolutionary | GA, differential evolution, PSO, simulated annealing, Nelder-Mead, island model, Metal GPU |
| Monte Carlo driver | `Simulation/MonteCarlo/MonteCarloSimulation.swift` (39K) |
| Retained trials | `SimulationResults.values: [Double]` |
| Sampling | Latin Hypercube, **Sobol, Halton, Owen scramble** |
| Correlated inputs | `CorrelationMatrix.swift`, `CorrelatedNormals.swift` |
| Statistics | `SimulationStatistics`, `Percentiles`, `RiskMetrics` |
| **Model compilation** | `MonteCarlo/Compilation/` — `BytecodeCompiler`, `BytecodeOptimizer`, `MonteCarloExpressionModel` |

That last row is the one that changes the shape of this work. BusinessMath already compiles a
model to bytecode once and evaluates it per trial — which is the architecture Frontline's
PSI interpreter uses, and the reason their product is fast. It is not a thing to build.

The sampling stack is, in one respect, **ahead** of Risk Solver: Sobol sequences with Owen
scrambling are not in Frontline's product.

GRG is the one real absence — no file mentions it, and upstream's own
`project/plans/upcoming/optimizations/GRG.md` marks it as planned. But Solver's GRG Nonlinear is
gradient descent with active-set constraint handling and multistart, and all three pieces are
present. That is an assembly job, and it is out of scope here regardless: **this proposal is
simulation only.** Optimization gets its own proposal once the graph exists, because it needs the
same graph and nothing else.

---

## 3. Architecture

Four layers. Only the middle two are new.

```
 .xlsx ──► SwiftXLSX ──► ModelGraph ──► LoweredModel ──► MonteCarloSimulation ──► SimulationResults
                            │              (bytecode)                                    │
                            │                                                            │
                            └──────► interpreted trial loop ─────────────────────────────┘
                                     (FormulaEvaluator, mutable provider)                │
                                                                                         ▼
                                       FormulaEvaluator + SimulationResultProvider ──► PsiMean(B4)
```

**Layer 1 — `ModelGraph`.** A workbook's formula cells, the dependency edges between them, a
topological order, and two annotations from the recognizer: which cells are uncertain (they carry
a `Psi*` distribution) and which are outputs (they carry `PsiOutput()`).

**Most of this already exists.** `SwiftXLSX.DependencyGraph` is public and built straight from a
`Workbook`, with Kahn's topological sort, `evaluationOrder`, `inputs`, `outputs`,
`dependents(of:)`, `precedents(of:)`, `allDependents(of:)`, `isAcyclic` and `cycles`. An earlier
draft of this proposal listed building it as Phase 1 — the same error as §2, made the same way:
grepping *this* repository's `Sources/`, finding nothing, and concluding absence when the answer
was one dependency over. **`ModelGraph` wraps `DependencyGraph`; it does not replace it.** What is
genuinely new in Layer 1 is the recognizer — which cells are uncertain, which are outputs, and
lifting the sampler directives out of the AST.

**Layer 2 — the lowering pass.** `FormulaAST` over a graph of cells → BusinessMath `Expression`,
a scalar tree over indexed `[Double]` inputs. This is the only genuinely new algorithm.

**Layer 3 — the run.** `MonteCarloSimulation(iterations:enableGPU:seed:expressionModel:)`,
already public, already there.

**Layer 4 — read-out.** `PsiMean`, `PsiPercentile`, `PsiCVaR` and the other 84 `statistic` rows
evaluate against a completed run, supplied to the evaluator the same way cell values are.

### 3.1 The decision that de-risks the whole thing

**The lowering pass is an optimization, not a requirement.**

The interpreted path — mutate a `CellValueProvider`, re-run `FormulaEvaluator` in topological
order, once per trial — handles *every* formula the registry can already evaluate. All 160
functions, text, errors, `VLOOKUP`, the lot. It is slow, and it is always correct.

The bytecode path handles a subset, and is fast.

So the two are not alternatives to choose between. They are a correctness baseline and a fast
path that must agree, which is both the fallback strategy and, in §8, the best test in the suite.
A model that will not lower still runs. It just runs slowly, and says so.

This is the difference between a feature that ships when lowering is complete and one that ships
when lowering covers the first workbook.

---

## 4. The lowering pass

`FormulaAST` and `Expression` are closer than they have any right to be:

| `FormulaAST` | `Expression` | Note |
|---|---|---|
| `.number(Double)` | `.constant` | direct |
| `.cellRef` → uncertain cell | `.input(i)` | *i* assigned by the sampler |
| `.cellRef` → formula cell | inlined subtree | see §5.3 |
| `.cellRef` → constant cell | `.constant` | direct |
| `.add`/`.subtract`/`.multiply`/`.divide`/`.power` | `.binary(.add …)` | direct |
| `.negate` | `.unary(.negate, _)` | direct |
| six comparisons | six `BinaryOp` comparisons | direct |
| `IF(c,t,f)` | `.conditional(c,t,f)` | direct — `Expression` has a ternary |
| `SUM(range)` | `ExpressionArray.sum()` | present |
| `SUMPRODUCT(a,b)` | `ExpressionArray.dot(_:)` | present, and exactly right |
| `MIN`/`MAX`/`AVERAGE` | `.min`/`.max`/`ExpressionArray.mean()` | present |
| `ABS`/`SQRT`/`LN`/`EXP`/`SIN`/`COS`/`TAN` | `UnaryOp` | present |
| `.text`, `.concatenate` | — | §5.1 |
| `.error`, `.missing` | — | §5.1 |
| `VLOOKUP`/`INDEX`/`MATCH` | — | §5.2 |
| `OFFSET`/`INDIRECT` | — | never; §5.2 |

The two corpus formulas `PROPOSAL_psi_bindings.md` quotes both lower today with what is already
in the box:

```
=SUM(J2:J11)+_xll.PsiOutput()            → ExpressionArray.sum()
=SUMPRODUCT(D22:D26,E22:E26)+PsiOutput() → ExpressionArray.dot(_:)
```

That is not a coincidence worth relying on, but it is a reason to expect the first spike to
succeed.

---

## 5. The four hard edges

### 5.1 Excel's type system does not fit

`Expression` is `Double` in, `Double` out. Excel's value domain is a union — number, text,
boolean, error — and error *propagation* is a semantic this package deliberately gets right
today. Lowered into bytecode, `1/0` is `+inf`, not `#DIV/0!`.

**Decision:** the lowering pass refuses rather than approximates. A model whose trial path can
produce a text value or an Excel error does not lower; it interprets. `LoweringFailure` names the
cell. Silently turning `#DIV/0!` into a NaN that then poisons a mean is exactly the class of
plausible-wrong-number this project exists to avoid — and §7 of `master_plan.md` says so.

Booleans are the exception and are safe: Excel's `TRUE`/`FALSE` coerce to 1/0, and
`Expression`'s comparisons already return 1.0/0.0.

### 5.2 Data-dependent addressing has no opcode

87,773 `VLOOKUP` calls in the corpus. `Expression` has no indexing operation.

There is a real trick, and it is worth stating precisely because it decides how much of the corpus
is reachable. **If the lookup table is constant across trials and only the key varies**, a
`VLOOKUP` over an *n*-row table lowers to a chain of *n* `.conditional` nodes — branch-free,
O(*n*) per trial, and exactly correct including the approximate-match semantics. The table is
constant whenever no cell in it descends from an uncertain cell, which the graph already knows.

`INDEX`/`MATCH` lowers the same way. `OFFSET` and `INDIRECT` never do — their *address* is
computed, so the shape of the expression itself would vary per trial. Those interpret, always.

Cost control: the chain multiplies node count by table height, so a 500-row lookup inside a
10,000-trial loop is 5M conditional evaluations per output. The lowerer takes a
`maxUnrolledLookup` bound and declines beyond it rather than compiling something pathological.

### 5.3 Graph → tree, and the CSE problem

`Expression` is one scalar tree. A workbook is a DAG. Lowering inlines each referenced formula
cell's subtree into its referent — and a cell referenced *k* times is inlined *k* times.

`BytecodeOptimizer` does constant folding and algebraic simplification. It does **not** do common
subexpression elimination — I checked. So a deep model with heavy fan-out could blow up
exponentially in node count.

**Decision:** measure before mitigating. The lowerer reports `instructionCount()` and refuses past
a `maxInstructions` bound. If real corpus models blow the bound, the fix is CSE — and it belongs
upstream in `BytecodeOptimizer`, where it benefits every caller, not here. Recorded as
Open Question 15.1 rather than pre-solved.

### 5.4 Sampling identity, and what a trial *is*

Each uncertain cell becomes one index in `inputs: [Double]`. The sampler draws the vector; the
bytecode consumes it. Three consequences:

- **A distribution cell referenced twice is one draw, not two.** Excel would recompute a volatile
  function twice; Risk Solver draws once per trial per cell. The graph makes this automatic —
  the cell is one node with one input index — and it is the correct behaviour.
- **`PsiCorrMatrix` / `PsiCopula` constrain the joint draw**, so they configure the sampler, not a
  cell. `runCorrelated(...)` already exists for this. They are engine directives, and the
  recognizer must lift them out of the AST rather than trying to evaluate them.
- **Seeding is explicit and required.** `RandomSource` has no default by construction; this
  inherits that. A run without a recorded seed is not reproducible and the API will not permit
  one.

---

## 6. API surface

New module `SwiftExcelSimulation`, depending on `SwiftExcelFunctions` and `BusinessMath`. Kept out
of `SwiftExcelFunctions` because the evaluator's promise is that it takes no dependency on a
workbook or a run, and that promise is worth more than the convenience.

### 6.1 The graph

```swift
/// A workbook's formula cells, their dependency order, and what the recognizer found.
public struct ModelGraph: Sendable {
    public let formulas: [CellAddress: FormulaAST]
    public let constants: [CellAddress: CellValue]
    /// Topological order. Guaranteed acyclic — a cycle is a build-time error.
    public let evaluationOrder: [CellAddress]
    /// Cells carrying a `Psi*` distribution, in input-index order.
    public let uncertain: [UncertainCell]
    /// Cells carrying `PsiOutput()`.
    public let outputs: [CellAddress]
    /// Sampler configuration lifted out of the formulas: correlation, copulas, seeds.
    public let samplingDirectives: [SamplingDirective]

    public func dependents(of cell: CellAddress) -> Set<CellAddress>
    public func descendsFromUncertain(_ cell: CellAddress) -> Bool
}

public struct UncertainCell: Sendable {
    public let address: CellAddress
    public let distribution: DistributionSpec   // name + parsed arguments
    public let baseCase: Double?                // from PsiBaseCase, if present
    public let name: String?                    // from PsiName, if present
    public let inputIndex: Int
}

public struct ModelGraphBuilder: Sendable {
    public init(provider: any CellValueProvider, registry: FunctionRegistry)

    /// - Parameter roots: restrict the graph to these cells and their ancestors.
    ///   `nil` builds the whole sheet.
    public func build(roots: [CellAddress]? = nil) throws -> ModelGraph
}

public enum ModelGraphError: Error, Sendable, Equatable {
    case circularReference(cycle: [CellAddress])
    case unparseableFormula(at: CellAddress, underlying: String)
    case unknownDistribution(name: String, at: CellAddress)
    case malformedDistribution(name: String, at: CellAddress, reason: String)
    case noOutputs
}
```

### 6.2 Lowering

```swift
public struct LoweredModel: Sendable {
    public let output: CellAddress
    public let model: MonteCarloExpressionModel
    /// Input index → uncertain cell. Same order as `ModelGraph.uncertain`.
    public let inputs: [CellAddress]
    public let instructionCount: Int
}

public struct Lowerer: Sendable {
    public struct Limits: Sendable {
        public var maxInstructions: Int = 1_000_000
        public var maxUnrolledLookup: Int = 256
        public init()
    }

    public init(limits: Limits = Limits())

    public func lower(_ graph: ModelGraph, output: CellAddress) throws -> LoweredModel

    /// What *would* fail, without lowering anything.
    ///
    /// This is the measurement instrument for §8.2: run it across the corpus to
    /// learn which formulas are reachable by the fast path, before writing the
    /// lowering for any of them.
    public func audit(_ graph: ModelGraph) -> [LoweringFailure]
}

public enum LoweringFailure: Error, Sendable, Equatable {
    case unrepresentableFunction(name: String, at: CellAddress)
    case textValued(at: CellAddress)
    case errorValued(ExcelError, at: CellAddress)
    case computedAddress(function: String, at: CellAddress)
    case lookupTableVaries(at: CellAddress)
    case lookupTableTooLarge(rows: Int, limit: Int, at: CellAddress)
    case instructionLimitExceeded(count: Int, limit: Int)
}
```

`audit` returning `[]` is the precondition for `lower` succeeding. Both are pure functions of the
graph, which is what makes the corpus measurement cheap.

### 6.3 Running

```swift
public enum SamplingScheme: Sendable {
    case monteCarlo
    case latinHypercube
    case sobol(scrambled: Bool)
    case halton
}

public struct SimulationPlan: Sendable {
    public let compiled: [CellAddress: LoweredModel]
    public let interpreted: [CellAddress]
    public var usesFastPathThroughout: Bool { interpreted.isEmpty }
}

public struct WorkbookSimulator: Sendable {
    public init(
        graph: ModelGraph,
        trials: Int,
        seed: UInt64,
        sampling: SamplingScheme = .latinHypercube,
        limits: Lowerer.Limits = .init()
    )

    /// Which outputs took the fast path and which will interpret. No trials run.
    public func plan() -> SimulationPlan

    public func run() async throws -> SimulationRun
}

public struct SimulationRun: Sendable {
    public let results: [CellAddress: SimulationResults]
    public let trials: Int
    public let seed: UInt64
    public let sampling: SamplingScheme
    public let plan: SimulationPlan
    public let elapsed: Duration
}
```

`plan()` being separate from `run()` is deliberate: the SwiftUI app shows the user *before*
starting a long run that three of their eight outputs will interpret and why.

### 6.4 Read-out — the seam that makes `PsiMean` work

`PsiMean(B4)` cannot be a function of `B4`'s value. `B4` has ten thousand values. It has to reach
the run. This package already has the idiom for exactly this problem — `CellValueProvider` is a
protocol the caller supplies — so the answer is the same shape:

```swift
/// Where the `Psi*` statistic functions get a completed run.
///
/// Symmetric with `CellValueProvider`: the evaluator holds a reference and never
/// knows where the numbers came from. A caller with no run supplies nothing, and
/// every statistic answers `#N/A` — which is what Risk Solver itself shows before
/// a simulation has been run.
public protocol SimulationResultProvider: Sendable {
    func results(for cell: CellAddress) -> SimulationResults?
}

extension SimulationRun: SimulationResultProvider {}
```

`EvaluationContext` gains one optional field:

```swift
public struct EvaluationContext {
    // ... existing members unchanged
    public var simulation: (any SimulationResultProvider)?
}
```

Evaluation becomes two passes, which mirrors how the real product behaves:

1. Build the graph, plan, run. Needs no statistic function.
2. Evaluate the sheet with `context.simulation` populated. `PsiMean`, `PsiPercentile`, `PsiCVaR`,
   `PsiStdDev` and the rest now resolve.

`SimulationResults` already carries `values`, `statistics`, `percentiles`, `riskAnalysis`,
`confidenceInterval(level:)` and `probabilityAbove/Below/Between`. Most of the 87 `statistic`
rows are a line each on top of that. The `PsiTheo*` block (~18) does not need a run at all —
those are closed-form properties of the distribution and belong with the existing bindings.

---

## 7. Error handling

Three distinct failure domains, deliberately not merged:

| Domain | Type | Disposition |
|---|---|---|
| The workbook is not a model | `ModelGraphError` | **throws** — no graph, nothing to run |
| A formula won't compile | `LoweringFailure` | **degrades** — that output interprets |
| A trial produced nonsense | `SimulationError` (upstream) | **reported per output**, run continues |

The middle row is the important one and it is not an error in the user's sense — it is a
performance disclosure. It reaches the user as "this output ran interpreted, 340× slower, because
`D14` uses `OFFSET`", never as a failure.

Existing rules apply without exception: no force unwraps, guard-clause validation, and every
division checked. The lowerer's `divide` case is the one place where Excel semantics and IEEE
semantics diverge, and §5.1 resolves it by refusal rather than by a silent NaN.

---

## 8. Test strategy

### 8.1 Differential: the two paths must agree

The one that matters. For any model that lowers, compiling and interpreting with the same seed
must produce **bit-identical** trial vectors — same draws, same order, same arithmetic.

```swift
@Test("Compiled and interpreted paths agree bit-for-bit", arguments: fixtureModels)
func pathsAgree(_ fixture: ModelFixture) async throws {
    let graph = try ModelGraphBuilder(provider: fixture.provider, registry: .standard).build()
    let compiled = try await WorkbookSimulator(graph: graph, trials: 1_000, seed: 42).run()
    let interpreted = try await WorkbookSimulator(
        graph: graph, trials: 1_000, seed: 42, limits: .neverLower
    ).run()

    for output in graph.outputs {
        #expect(compiled.results[output]?.values == interpreted.results[output]?.values)
    }
}
```

This is the test that earns the two-path design. Every lowering rule added has to survive it, and
a wrong `VLOOKUP` unroll or a mis-ordered input index fails it immediately. `SpillIntegrationTests`
is cited in `master_plan.md` as the test that earned its keep the day it was written; this is the
same bet.

### 8.2 Corpus audit — the coverage number that actually gates this

`Lowerer.audit` over the 41 Risk Solver workbooks, reported as a distribution of
`LoweringFailure` by function name. This is **not** the coverage number the matrix tracks. The
matrix asks "can the registry answer this function?"; this asks "can this function survive a
trial loop?" A function can be `have` and still be unlowerable.

Run this *before* writing lowering rules. The failure histogram is the work list, ordered by
corpus frequency, and it may well say that six rules reach 90% of the models.

### 8.3 Oracle

`ExcelOracleTests` already checks every formula against Excel's cached value. Extend it: for a
workbook with `PsiBaseCase` present, evaluating with **no** simulation must reproduce the base
case. `PROPOSAL_psi_bindings.md` measured this — of 90 cells carrying an explicit `PsiBaseCase(X)`,
71 cache the value at X. Those 71 are a free oracle for the base-case path.

The other 19 cached a draw and cannot be checked this way. They are not a failure; they are the
reason a seeded run is not comparable to a saved file, and the test must skip them explicitly
rather than fudging a tolerance.

### 8.4 Statistical

Fixed seed, known distribution, closed-form answer. `PsiMean` of `PsiNormal(100, 15)` over 100,000
Sobol draws against 100. Tolerance derived from the standard error, not chosen to make it pass —
and stated in the test.

Convergence gets its own: Sobol should reach a given tolerance in materially fewer trials than
plain Monte Carlo. If it does not, the sampler is wired up wrong, and no accuracy test would
notice.

### 8.5 Graph

Cycle detection (`A1=B1+1, B1=A1+1` throws with the cycle named), topological order correctness,
fan-out inlining, `descendsFromUncertain` correctness — that last one gates the §5.2 lookup trick,
so a wrong answer there is a silently wrong simulation.

---

## 9. Performance

No numbers are claimed here; these are the targets and the instruments.

**The thing being avoided.** Round-tripping each trial through a host application's calculation
engine costs a process or bridge hop per trial. That is what makes an in-Excel implementation
untenable and is the whole reason the graph exists. The comparison to beat is not Frontline's
product; it is "ask the host to recalculate," which loses by orders of magnitude.

| Path | Expectation | Measured by |
|---|---|---|
| Bytecode, CPU | target ≥ 10⁵ trials/sec on a small model | `PerformanceBenchmark` (upstream) |
| Bytecode, Metal GPU | `enableGPU: true` already exists; unmeasured here | same |
| Interpreted | **measured 2026-09-08: 118× on marginal propagation cost** | `Phase0LoweringSpikeTests` |

### 9.1 Phase 0 result — answered, and it moves Phase 4 up

Measured with `Phase0LoweringSpikeTests`, 10,000 trials, seed 42, sweeping propagation depth so
the shared sampling cost cancels in the slope. **Release build:**

| depth | instructions | interpreted | compiled | whole-run |
|---:|---:|---:|---:|---:|
| 0 | 3 | 0.033s | 0.022s | 1.5× |
| 50 | 103 | 0.287s | 0.024s | 12.0× |
| 100 | 203 | 0.546s | 0.026s | 20.9× |
| 500 | 1003 | 2.497s | 0.043s | **58.1×** |

Marginal cost of one propagation operation per trial: **interpreted 493 ns, compiled 4.2 ns —
118×.** The whole-run column is still climbing at depth 500; it has not plateaued.

This lands on the "lowering coverage is the product" side of the question §9 posed, not the
"fast path is a nicety" side. A 500-operation model — unremarkable for a real workbook — costs
2.5s interpreted against 0.043s compiled at 10,000 trials, and 25s against 0.43s at 100,000.
That is the difference between a tool someone uses and one they abandon.

**The trap, recorded because it nearly produced the opposite plan.** The same sweep in a *debug*
build reports **3.8×**. Optimization makes the bytecode path ~70× faster and the AST walk only
~2.3× faster, so debug understates the ratio by about 31×. Had Phase 0 been run in the default
configuration and believed, the conclusion would have been that lowering barely matters and the
SwiftUI work should come first. Any future measurement here runs `-c release` or is not run.

Two reasons 118× is a floor rather than a ceiling: the propagation step measured is `+ 1.0`,
where a real formula dispatches through the registry and reads ranges; and the provider is a
dictionary, where a workbook-backed one costs more. Both make the interpreted side more
expensive.

**Consequence for §13:** Phase 4 (lowering rules) moves ahead of Phase 6 (SwiftUI). §3.1 still
stands — the interpreted path remains the correctness baseline and the differential test — but it
is now clearly a fallback rather than a plausible shipping configuration for large models.

Watch items: node-count blowup from inlining without CSE (§5.3), and `SimulationResults.values`
holding `trials × outputs` doubles — 10⁵ trials × 20 outputs is 16 MB, fine; 10⁷ × 100 is not.
Retention becomes opt-in per output past a threshold, since the statistics are streamable even
when the vector is not retainable.

---

## 10. The SwiftUI front end

Deliberately thin. It is a window onto `SimulationRun`, and it holds no modelling logic.

- **Open** an `.xlsx`, show the sheet, highlight uncertain cells and outputs as the recognizer
  found them. This view alone is useful before a single trial runs — it is a Risk Solver model
  reader for a platform that has none.
- **Plan**, showing which outputs compile and which interpret, with the `LoweringFailure` reason
  in plain language next to the cell.
- **Run**, with trial count, seed (defaulted, always visible, always editable) and sampling scheme.
- **Results**: histogram, CDF, percentile table, the risk metrics `SimulationResults` already
  computes. `Percentiles` and `RiskMetrics` exist; this is presentation.
- **Tornado / sensitivity**, later — it needs per-input rank correlation against the output.
  `spearmansRho(_:vs:)` is upstream and covers `PsiSpearmanRho`. `PsiKendallTau` has **no**
  upstream source: BusinessMath has `kendallW`, the coefficient of concordance, which is a
  different statistic and not a substitute. That row belongs on `project/plans/proposals/Excel conformance/psi_upstream_gaps.md`.

The seed being on screen and editable rather than hidden is a small decision with a large
consequence: it makes every screenshot reproducible, which is what `RandomSource`'s
"deterministic by construction" stance is for.

---

## 11. Hosts

The graph is host-agnostic. Everything below is optional delivery, and none of it is on the
critical path.

### 11.1 Excel for Mac — poor fit, and now for a documented reason

XLL and COM are Windows-only, so Office.js is the only supported path. Two blocks:

- **Namespacing.** A custom function registers as `NAMESPACE.PSINORMAL`. It cannot be
  `PsiNormal`. Existing Risk Solver workbooks would not work unmodified, which removes the main
  reason to be a plugin at all.
- **Statelessness.** An Office.js custom function receives values and returns a value. There is
  no argument shape in which `PSIMEAN` receives ten thousand trials. §6.4's provider seam has no
  equivalent on that side of the bridge.

An Office.js add-in remains viable for the **base case only** — one pass, no simulation, backed
by the existing bindings. That is genuinely useful and it is a separate, smaller proposal.

### 11.2 LibreOffice Calc — a materially better host

Checked rather than assumed, and it is better than Excel on all three axes:

- **Real function names.** A Calc add-in implements `XAddIn` + `XServiceName`, declares its
  functions through `getFunctionCount`/`getFunctionData`, and they appear in the Function Wizard
  under their own names. No forced prefix. `PSINORMAL` can be `PSINORMAL`.
- **Long-lived components.** A UNO component is an object with a lifetime, not a stateless
  callback. It can own a completed run and answer `PsiMean(B4)` from it — the thing Office.js
  structurally cannot do. §6.4's `SimulationResultProvider` maps onto it directly.
- **A pluggable optimizer socket that already exists.** `com.sun.star.sheet.XSolver` is a
  documented service: `Document`, `Objective`, `Variables`, `Constraints`, `Maximize`, `solve()`,
  then `Success`, `ResultValue`, `Solution`. LibreOffice ships lp_solve, CoinMP and the DEPS/SCO
  evolutionary engines against it in module `sccomp`. **A BusinessMath solver could register as
  another engine and appear in Calc's own Solver dialog** — no bespoke UI, no reverse engineering.
  That is a real finding and it is the strongest argument in this section.

There is no equivalent socket for simulation, so the SwiftUI app (or a UNO sidebar) still owns
that surface.

The cost is the language boundary: UNO has no Swift binding. Two routes, and the second is the
one to prototype — LibreOffice bundles Python with UNO bindings on macOS, so a Python-UNO
extension calling a Swift dylib through a C ABI shim is a days-long spike, where a C++ UNO
component wrapping the same shim is a weeks-long one.

**Recommendation:** SwiftUI app first and unconditionally. LibreOffice second, and specifically
`XSolver` first within it, because it is the highest ratio of capability to work anywhere in this
document. Excel last, base case only, or never.

---

## 12. Writing back — reporting an error is not fixing one

The pipeline above is one-way: `.xlsx` in, results out. That is enough to *report* a disagreement,
which is already the master plan's motivating application — "read a model, recompute it, and
report where it disagrees with itself." It is not enough to **fix** one, and the moment the
SwiftUI app shows a user a wrong cell, the next thing they will want is a button.

Those are two capabilities, and only one is expensive.

**Reporting is available now.** Read-only, no new dependency, no risk. A CLI or the app pointing
at the offending cell with the recomputed value beside the cached one needs nothing this proposal
does not already build.

**Fixing is blocked, and the block is silent.** `SwiftXLSX.Workbook.save()` regenerates the
archive from seven part types, and `Workbook(xlsxData:)` retains only `sheets` and `namedRanges` —
`WorkbookReader.read(from:)` builds an `entryMap` of every part, consumes six, and drops the rest
when the function returns. So open-edit-save on a real workbook **destroys** charts, pivot tables
and their caches, VBA, drawings, images, themes, comments, tables, conditional formatting, data
validation, print settings, external links and document properties.

That behaviour is correct for the case it was built for — a `Workbook()` composed in code and
written out — and it is data loss for the case of opening someone's model. Nothing in the API
distinguishes the two, which is what makes it dangerous rather than merely limited. Risk Solver
workbooks are close to the worst case: they are business models, so charts and formatting are
exactly what they carry.

**The fix belongs upstream, and it has its own proposal.**
`SwiftXLSX/project/plans/proposals/PROPOSAL_surgical_save.md` — retain the source archive, copy
every unparsed part through byte-for-byte, and rewrite only what changed. It is scoped there
rather than here for three reasons: it benefits every SwiftXLSX consumer, it is testable with no
reference to simulation (read a workbook, change nothing, assert byte-identity), and it can be
implemented in a separate session without touching this work.

Three constraints from that proposal matter to callers here, because they shape what this project
can promise:

- **Shared-string and style indices are positional**, so a surgical save appends and never
  compacts. A sheet this project rewrites must not renumber a table that unparsed sheets still
  index into.
- **`xl/calcChain.xml` is dropped** on any save that touched a formula, and `fullCalcOnLoad` is
  set on `<calcPr>`. Without that, a corrected cell leaves its dependents' cached values stale —
  and `ExcelOracleTests` treats those caches as ground truth, so writing a file with stale ones
  would poison the very corpus this project tests against.
- **Structural change is out of scope.** Adding or removing sheets in a read workbook throws
  rather than falling back to the destructive path.

**Until surgical save lands, this project writes no `.xlsx` it did not create.** Corrections are
reported, or written to a *new* workbook alongside the original — never in place. That is a
deliberate constraint, not an oversight, and it should be stated in the UI rather than discovered.

---

## 13. Phasing

Each phase ends somewhere shippable.

| # | Deliverable | Ends when |
|---|---|---|
| **0** | **Spike.** Hand-built `ModelGraph` for one arithmetic model, lower it, run 10,000 trials, print the mean. Measure the interpreted:compiled ratio (§9). | The ratio is a number, not an assumption |
| **1** | `ModelGraph` over `SwiftXLSX.DependencyGraph`, + the recognizer | A corpus workbook builds a graph with its uncertain cells and outputs marked |
| **2** | `Lowerer.audit` + corpus histogram (§8.2) | The lowering work list is ordered by evidence |
| **3** | Interpreted path, end to end, `PsiMean`/`PsiStdDev`/`PsiPercentile` bound via §6.4 | A real workbook simulates correctly, slowly |
| **4** | Lowering rules, top-down by the phase-2 histogram, each under the §8.1 differential test | Diminishing returns on the histogram |
| **5** | The remaining `statistic` rows | 87 rows resolved |
| **6** | SwiftUI app | It opens a workbook and draws a histogram |
| **7** | Write-back, **gated on `PROPOSAL_surgical_save.md`** | A corrected cell is written to a real workbook and its charts, pivots and macros survive |
| **8** | LibreOffice `XSolver` spike | Out of scope for this proposal; needs the optimization one |

Phase 3 ships a working product. Phase 4 makes it fast. That ordering is the point — and it is
only available because of §3.1.

---

## 14. Alternatives considered

**Ask Excel or LibreOffice to recalculate per trial.** Rejected; §9. It is the architecture that
makes the feature impossible rather than slow.

**Lower everything; refuse models that won't compile.** Rejected. It makes shipping conditional on
lowering completeness, and §5.2 guarantees some models never lower. The two-path design costs one
extra implementation and buys unconditional correctness plus the best test in the suite.

**Put the graph in `SwiftExcelFunctions`.** Rejected. The evaluator's stated promise is that it
takes no dependency on a workbook or a run. A new module keeps that true.

**Approximate Excel errors as NaN in bytecode.** Rejected; §5.1. A NaN that propagates into a mean
produces a plausible wrong number, which `master_plan.md` §7 names as the failure mode this
project exists to prevent.

**Extend `Expression` upstream with a text type and an indexing opcode.** Deferred, not rejected.
It would enlarge the lowerable set considerably. But it changes BusinessMath's bytecode VM for one
downstream consumer's benefit, and the phase-2 histogram should decide whether it is worth it. If
`VLOOKUP` dominates the failures, an indexing opcode upstream beats the §5.2 unroll on every axis.

---

## 15. Legal

Frontline Systems owns "Solver", "Risk Solver" and "Analytic Solver" as marks; Microsoft licenses
the bundled Excel Solver from them. Function names and signatures are reimplementable, and reading
a file format is not infringement. Three rules for anything that ships:

- The product is not called Solver, Risk Solver, or a near variant.
- No documentation prose is copied. The trap list in `master_plan.md` is derived from published
  behaviour and stays that way — parameter orders are facts, not expression.
- `Psi*` compatibility is described as compatibility, in our own namespace, and never presented as
  the product itself.

---

## 16. Open questions

1. **Does inlining without CSE blow up on real models?** (§5.3) Phase 2 answers it. If yes, CSE
   goes upstream in `BytecodeOptimizer`, benefiting every BusinessMath caller.
2. **What is the interpreted:compiled ratio?** (§9) Phase 0 answers it, and the answer reorders
   phases 4 through 6.
3. **Does the §5.2 lookup unroll survive real table sizes,** or does the corpus's `VLOOKUP` usage
   sit past any sane `maxUnrolledLookup`? Phase 2 answers it.
4. **Multi-output sharing.** Eight outputs over one uncertain input set currently means eight
   independent trees and eight compilations. `MonteCarloExpressionModel` evaluates to a single
   scalar. Is there a multi-output form, or does this want one run per output over an identical
   seeded draw sequence? The latter is correct and wasteful; resolve in phase 4.
5. **`PsiSimParam` / parameterised runs** — 26 workbooks carry `PsiOptParam` and the corpus has
   `PsiSimParam`. These sweep a run across parameter values, which is a loop *around* the
   simulation. Deferred to the optimization proposal.
6. **Where does the recognizer live?** `master_plan.md` refers to it as a known future component
   for `PsiOutput`. This proposal needs it. It may belong in `SwiftExcelFunctions` next to the
   AST, not in the new module.

---

## 17. Documentation strategy

DocC on every public symbol, per the standing rule. Three articles beyond the reference:

- **"Running a workbook"** — the end-to-end path, graph to histogram.
- **"Why some models interpret"** — §5's four edges, written for the person reading a
  `LoweringFailure` in the app and wanting to know what to change in their spreadsheet.
- **"Reproducibility"** — seeds, sampling schemes, and the honest statement that a seeded run does
  not reproduce a number cached by Frontline's add-in, with the 71/19 `PsiBaseCase` measurement as
  the evidence.
- **"What this writes, and what it will not"** — §12's constraint, stated before a user goes
  looking for a save button. Until surgical save lands, corrections are reported or written to a
  new workbook; this project does not modify an `.xlsx` it did not create.

---

**Next step:** ~~Phase 0. One hand-built graph, one lowered model, one number, and the
interpreted:compiled ratio measured rather than guessed.~~ **Done 2026-09-08 —
`Phase0LoweringSpikeTests`, and the answer is 118×.** See §9.1. Both paths agree bit-for-bit at
every depth, which also means §3.1's differential contract holds in practice and not just on paper.

Phase 1 next, and it is smaller than this proposal originally scoped it: `SwiftXLSX.DependencyGraph`
already provides the topological order, cycle detection and the precedent/dependent queries, so
Phase 1 is `ModelGraph` wrapping it plus the recognizer. Then Phase 2's corpus histogram, which is
the other number the ordering depends on.

Write-back (§12) is gated on `SwiftXLSX/project/plans/proposals/PROPOSAL_surgical_save.md` and can
proceed independently, in a separate session, without touching any of the above.
