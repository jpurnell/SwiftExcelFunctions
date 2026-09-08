# SwiftExcelFunctions Capability Map

**Purpose:** Scannable inventory of what this project can do — feature areas, key types, external interfaces, and application domains.

**Last reviewed:** 2026-09-08 (v0.6.0)

> **Format reference:** See `development-guidelines/rules/capability_map.md` for field definitions,
> naming conventions, and maintenance rules.

---

## Formula Evaluation

**Key types:** `FormulaEvaluator`, `EvaluationContext`, `ExcelFunction`, `FunctionRegistry`
**Interfaces:** internal only — consumed by BusinessMathExcel and SwiftXLSX callers
**Applications:** Evaluate a parsed `FormulaAST` against a `CellValueProvider`, with Excel's own
argument order, type coercion and error propagation. `spill(_:over:)` distributes one array
formula's result across the range it was entered over.
**Dependencies:** SwiftExcelCore for the vocabulary; SwiftXLSX is test-only.

## The Excel Function Library

**Key types:** `BuiltinMathFunctions`, `BuiltinStatsFunctions`, `BuiltinFinancialFunctions`,
`BuiltinLogicFunctions`, `BuiltinTextFunctions`, `BuiltinNavigationFunctions`,
`BuiltinDateTimeFunctions`, `BuiltinAggregationFunctions`, `BuiltinArrayFunctions`
**Interfaces:** `FunctionRegistry.builtin`
**Applications:** 160 of Microsoft's 519 documented worksheet functions. Names resolve through
Excel's `_xll.` and `_xlfn.` prefixes and through an alias table, so a workbook's older spellings
answer without the caller knowing they are older.

## Risk Solver Simulation

**Key types:** `BuiltinRiskSolverFunctions`, `BuiltinRiskSolverAltDistributions`,
`RandomSource`, `SeededRandomSource`, `RandomSourceGenerator`
**Interfaces:** `FunctionRegistry.builtin`
**Applications:** 109 Frontline `Psi*` functions — 106 of its 113 distribution rows — so a
workbook built with Risk Solver can be read without the add-in. Distributions sample by inverse
transform from a caller-supplied `RandomSource`; the package holds no entropy of its own and
answers `#VALUE!` rather than inventing a draw.
**Dependencies:** BusinessMath for every distribution's mathematics.

## Mathematics Bindings

**Key types:** `BuiltinBindingFunctions`, `BuiltinFinanceStatsBindings`
**Interfaces:** internal only
**Applications:** Excel-facing names over BusinessMath's computations, where the whole job is the
seam: argument order (`SLOPE(known_y, known_x)` against `slope(x, y)`), parameterisation
(`PsiLogNormal`'s arithmetic moments against a log-scale type), and Excel's error conventions.

## Correctness Apparatus

**Key types:** `ExcelOracleTests`, `MicrosoftSpecificationTests`, `OracleReport`, `OracleTolerance`
**Interfaces:** `BUSINESSMATHEXCEL_ORACLE=1` / `BUSINESSMATHEXCEL_CORPUS` environment variables
**Applications:** Two overlapping suites that fail for different reasons — every formula checked
against the value Excel itself cached in real workbooks (99.62% over 155,897 cells), and the same
rules taken from the published reference so they run on a clean checkout with no corpus.
Governed by ADR-001: Excel is the specification.
