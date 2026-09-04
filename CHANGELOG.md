# Changelog

All notable changes to SwiftExcelFunctions will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-04

Excel's function library, extracted from SwiftXLSX. One registry, asked for any function by the
name Excel uses — a caller never needs to know which package computes it.

### Added

- **73 Excel functions** across eight areas: aggregation, math, statistics, financial, date,
  logical, lookup, text.
- `FunctionRegistry` — copy-on-write, with `.builtin` preloaded and `register(_:)` for additions.
- `ExcelFunction` — a name, an arity, and a closure over values.
- `FormulaEvaluator` — walks a `FormulaAST`, resolving cell references through a
  `CellValueProvider`, named ranges through a `NameResolver`, and calls through the registry.
- `EvalError` — evaluation's own error type, mapped to `ExcelError` at the boundary.

### Notes

**No file format.** Give it a formula tree and any `CellValueProvider` and it evaluates — no
archive, no workbook, no I/O. That is what makes it usable alone, and what makes a binding
testable against a published value without opening a spreadsheet.

**The mathematics is delegated.** BusinessMath owns it; a second `NPV` that could disagree with
the first is the failure this arrangement exists to prevent. What belongs here is Excel's
semantics: argument order, type coercion, error propagation, and the sign conventions Excel
applies where a mathematics library correctly does not.

Moved unchanged, with their tests — 546 passing, including 49 parse-and-evaluate integration
cases that use SwiftXLSX's parser through a test-only dependency.

### Coverage

Against Microsoft's 519 documented worksheet functions: 72 present, 84 bindable against
mathematics BusinessMath already computes, 6 verified absent, 10 out of scope, 347 unreviewed.
Risk Solver's 295 PSI functions: 50 bindable, 13 role declarations rather than functions.
See `project/plans/excel_function_coverage_matrix.tsv`.

[Unreleased]: https://github.com/jpurnell/SwiftExcelFunctions/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jpurnell/SwiftExcelFunctions/releases/tag/v0.1.0
