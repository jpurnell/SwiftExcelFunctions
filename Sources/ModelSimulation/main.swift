import Foundation
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX

/// Turns a static Superchem model into a simulated one, runs it, and writes both back.
///
/// ## What this demonstrates
///
/// The model is a real one — a Tuck decision-science case answer from 2011, built the way
/// spreadsheets are built: every input a single number, every output a single number. It says
/// the Ultra project returns **2.61×** its R&D spend against a hurdle of **5×**, so: reject.
///
/// That answer is computed at one point. The case says the price is uncertain, the product
/// life is uncertain, and the plant *only runs when price exceeds cost* — an option the
/// single-point model cannot express, because at one price the plant is either on or off and
/// never both. Simulation is what lets the same model carry the uncertainty that was in the
/// case all along.
///
/// ## What is changed, and why each change is necessary
///
/// | cell | was | becomes |
/// |---|---|---|
/// | `C4` price | `45` | `PsiNormal(47.5, 6.25)` — 2σ at $35 and $60 |
/// | `C6` production | `30000` | `PsiNormal(30000, 2500)` |
/// | `C25` barrels | `IF(C19="Yes", C6, 0)` | also requires price > cost |
/// | `C48` year 7 | **a hardcoded number** | the formula its neighbours have |
///
/// `C48` is not a modelling choice — it is a **defect**. The cell holds `69276.345961` where
/// `C42:C47` hold formulas, so year seven's cash flow was frozen at whatever the inputs were
/// when someone last typed it. A static model hides that forever: the number is right for the
/// inputs it was computed at. The moment anything varies, one of the seven years stops moving.
@main
struct ModelSimulation {

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            report("usage: <in.xlsx> <out.xlsx> [trials] [seed] [priceMean priceSigma]")
            exit(1)
        }
        let trials = arguments.count > 3 ? Int(arguments[3]) ?? 10_000 : 10_000
        let seed = arguments.count > 4 ? UInt64(arguments[4]) ?? 20_260_921 : 20_260_921

        // Optional: a different price assumption, so the one that was asked for can be
        // compared against the case's own numbers rather than only asserted about.
        let edits: Edits
        if arguments.count > 6, let mean = Double(arguments[5]), let sigma = Double(arguments[6]) {
            edits = Edits(priceMean: mean, priceSigma: sigma)
        } else {
            edits = Edits()
        }

        let workbook = try Workbook(xlsxData: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        guard let source = workbook.sheets.first else {
            report("the workbook has no sheets"); exit(1)
        }

        // 1. Read the model as it stands.
        var sheet = CellSheet()
        let provider = WorkbookValueProvider(workbook: workbook, currentSheet: source.name)
        for row in 1...60 {
            for column in 1...4 {
                let ref = CellRef(column: column, row: row)
                guard let value = provider.value(at: ref, inSheet: source.name) else { continue }
                sheet[ref.reference] = value
            }
        }

        let asFound = try answer(from: sheet)

        // 2. The same model at the *mean* of the distributions, with the defect fixed and the
        //    shutdown option in place — everything the simulation changes except the
        //    uncertainty itself. Without this the comparison credits the simulation for a
        //    price assumption that was moved by hand.
        var atMean = sheet
        atMean["C4"] = .number(edits.priceMean)
        atMean["C6"] = .number(Edits.productionMean)
        atMean["C25"] = .formula(try FormulaParser.parse(Edits.barrels), cached: nil)
        atMean["C48"] = .formula(try FormulaParser.parse(Edits.yearSeven), cached: nil)
        let atMeanAnswer = try answer(from: atMean)

        // 3. Make it uncertain.
        for (ref, formula) in edits.all {
            sheet[ref] = .formula(try FormulaParser.parse(formula), cached: nil)
        }

        // 4. Run it.
        let survey = ModelSurveyor().survey(sheet)
        guard survey.isSimulable else {
            report("nothing in the model varies"); exit(1)
        }
        // What a GUI would list: every uncertain cell, its distribution, its parameters.
        for input in survey.uncertain {
            let shown = input.call.parameters.map { FormulaSerializer.serialize($0) }
            say("  input \(input.inputIndex): \(input.address.reference)  "
                + "\(input.call.function)(\(shown.joined(separator: ", ")))"
                + (input.call.label.map { "  \"\($0)\"" } ?? "")
                + (input.call.unhandledProperties.isEmpty ? ""
                   : "  UNHANDLED: \(input.call.unhandledProperties.joined(separator: ", "))"))
        }
        say("  outputs: \(survey.outputs.map(\.reference).sorted().joined(separator: ", "))")

        let run = try InterpretedRun.run(
            survey: survey, over: sheet, names: NoNames(),
            trials: trials, seed: seed)

        guard let npv = run.results(for: CellRef(Edits.expectedNPV)),
              let ratio = run.results(for: CellRef(Edits.ratio)) else {
            report("the run collected no outputs"); exit(1)
        }

        // 5. Say what happened, and write it down.
        let summary = Report(
            asFound: asFound, atMean: atMeanAnswer, npv: npv, ratio: ratio,
            barrels: run.results(for: CellRef(Edits.barrelsCell)),
            production: run.results(for: CellRef(Edits.productionCell)),
            trials: trials, seed: seed, sheet: sheet)
        say(summary.console)
        try Writer.write(report: summary, sheet: sheet, source: source,
                         to: URL(fileURLWithPath: arguments[2]))
        report("wrote \(arguments[2])")
    }

    /// The model's two outputs, evaluated once at the numbers it already holds.
    private static func answer(from sheet: CellSheet) throws -> (npv: Double, ratio: Double) {
        // Evaluated in order so each reads the one before it, exactly as a recalculation does.
        var ordered = sheet
        let graph = DependencyGraph(
            cells: sheet.populatedCells().map { CellAddress(sheet: "", cell: $0) },
            provider: sheet)
        for address in graph.evaluationOrder {
            guard case .formula(let ast, _)? = sheet[address.cell.reference] else { continue }
            let value = try FormulaEvaluator.evaluate(ast, cells: ordered, names: NoNames())
            ordered[address.cell.reference] = value
        }
        func number(_ ref: String) -> Double {
            if case .number(let n)? = ordered[ref] { return n }
            return 0
        }
        return (number(Edits.expectedNPV), number(Edits.ratio))
    }

    /// A number at the precision its size deserves.
    ///
    /// Swift-native rather than `String(format:)`, which bridges to the C `printf` ABI — the
    /// gate rejects it, and rightly: a `%s` against a Swift `String` is a runtime crash that
    /// nothing catches at compile time.
    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(
            .fractionLength(value.magnitude >= 1000 ? 0 : 3)).grouping(.never))
    }
}
