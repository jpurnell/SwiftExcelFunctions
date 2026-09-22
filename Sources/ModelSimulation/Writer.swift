import Foundation
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX

/// Writes the simulated model and its results back out as a workbook.
///
/// **The `Psi*` formulas are written as formulas**, which is what makes this the model rather
/// than a report about one. Excel shows `#NAME?` for them unless Risk Solver is installed —
/// they are Frontline's functions, not Microsoft's — so every cell also carries the value this
/// run computed, and the `Simulation` sheet carries the distribution as numbers. Nothing on
/// that sheet needs an add-in to read.
enum Writer {

    static func write(report: Report, sheet: CellSheet, source: Worksheet, to url: URL) throws {
        let out = Workbook()
        let model = out.addSheet(name: "Model")
        let results = out.addSheet(name: "Simulation")

        // The model, as edited, with its original labels beside it.
        for row in 1...56 {
            for column in 1...3 {
                let ref = CellRef(column: column, row: row).reference
                guard let value = sheet[ref] else { continue }
                switch value {
                case .formula(let ast, _):
                    model.writeFormula(FormulaSerializer.serialize(ast), to: ref)
                case .text(let text): model.write(text, to: ref)
                case .number(let number): model.write(number, to: ref)
                case .bool(let flag): model.write(flag ? "TRUE" : "FALSE", to: ref)
                default: break
                }
            }
        }
        annotate(model, report: report)
        summarise(results, report: report)
        try out.save(to: url)
    }

    /// Notes against the cells that changed, so the workbook explains itself.
    private static func annotate(_ sheet: Worksheet, report: Report) {
        sheet.write("← PsiNormal(47.5, 6.25): 2σ at $35 and $60", to: "E4")
        sheet.write("← PsiNormal(30000, 2500)", to: "E6")
        sheet.write("← unused by the model: production is not capped at capacity", to: "E12")
        sheet.write("← now requires price > cost (the case's shutdown option)", to: "E25")
        sheet.write("← was a hardcoded 69276.345961; the other six years were formulas", to: "E48")
        sheet.write("← PsiOutput(): collected each trial", to: "E51")
        sheet.write("← PsiOutput(): collected each trial", to: "E53")
    }

    /// The distribution, as numbers, on a sheet that needs no add-in.
    private static func summarise(_ sheet: Worksheet, report: Report) {
        var row = 1
        func line(_ label: String, _ value: String) {
            sheet.write(label, to: "A\(row)"); sheet.write(value, to: "B\(row)"); row += 1
        }
        func number(_ label: String, _ value: Double) {
            sheet.write(label, to: "A\(row)"); sheet.write(value, to: "B\(row)"); row += 1
        }

        sheet.write("Superchem, Ultra — simulation", to: "A1"); row = 3
        number("Trials", Double(report.trials))
        number("Seed", Double(report.seed))
        row += 1

        sheet.write("Expected NPV ($000s)", to: "A\(row)"); row += 1
        number("  as found (price 45)", report.asFound.npv)
        number("  at the means", report.atMean.npv)
        number("  mean", report.npv.statistics.mean)
        number("  median", report.npv.statistics.median)
        number("  std dev", report.npv.statistics.stdDev)
        number("  5th percentile", report.npv.percentiles.p5)
        number("  95th percentile", report.npv.percentiles.p95)
        number("  P(NPV > 0)", report.probabilityPositive)
        row += 1

        sheet.write("Expected NPV / R&D investment", to: "A\(row)"); row += 1
        number("  hurdle", Report.hurdle)
        number("  as found (price 45)", report.asFound.ratio)
        number("  at the means", report.atMean.ratio)
        number("  move from the price assumption", report.assumptionMove)
        number("  move from the uncertainty", report.uncertaintyMove)
        number("  mean", report.ratio.statistics.mean)
        number("  median", report.ratio.statistics.median)
        number("  std dev", report.ratio.statistics.stdDev)
        number("  5th percentile", report.ratio.percentiles.p5)
        number("  95th percentile", report.ratio.percentiles.p95)
        number("  P(clears the 5x hurdle)", report.probabilityOfClearingHurdle)
        row += 1

        sheet.write("What only a distribution shows", to: "A\(row)"); row += 1
        number("  P(plant idle: price below cost)", report.probabilityIdle)
        number("  P(production over design capacity)", report.probabilityOverCapacity)
        row += 1

        line("Decision", report.probabilityOfClearingHurdle < 0.5 ? "Reject" : "Investigate")
    }
}
