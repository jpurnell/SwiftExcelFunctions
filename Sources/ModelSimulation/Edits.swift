import Foundation

/// The four edits that turn the static model into a simulated one.
///
/// Each is written here rather than typed into the sheet, so the change from the original is
/// a list somebody can read and argue with — which is the part a GUI has to make visible.
struct Edits {

    /// Built with the price assumption to use, rather than mutating a global: a CLI flag
    /// that reaches the model by way of shared mutable state is a flag that can be read
    /// before it is written.
    init(priceMean: Double = 47.5, priceSigma: Double = 6.25) {
        self.priceMean = priceMean
        self.priceSigma = priceSigma
    }


    /// Where the answers live.
    static let expectedNPV = "C51"
    static let ratio = "C53"

    /// The market price, `C4`.
    ///
    /// **2σ at $35 and $60** puts the mean at `47.5` and σ at `6.25`. Worth saying plainly:
    /// this is *not* the case's own range. The case reports a 10-year average of **$55** with
    /// a low of $45 and a high of $75, so this distribution is materially more pessimistic —
    /// its mean sits $7.50 below the case's average and its upper 2σ below the case's *low*
    /// is not quite reached. The answer below is the answer to the question as asked.
    var price: String { "PsiNormal(\(priceMean), \(priceSigma))" }

    /// $47.50 — the midpoint of $35 and $60.
    ///
    /// **This is not the model's own price**, which was `45`, and it is not the case's either.
    /// Moving it is a change of assumption, and its effect has to be separated from the
    /// simulation's or the comparison credits uncertainty for an input somebody retyped.
    let priceMean: Double

    /// $6.25 — half the distance from the mean to $60, so $35 and $60 are the 2σ marks.
    let priceSigma: Double

    /// Production, `C6`, in thousands of barrels: mean 30,000, σ 2,500.
    ///
    /// The plant's design capacity is 30,000 — `C12` — and **the original model never reads
    /// that cell**. Production above capacity is therefore unconstrained here, which matches
    /// the case ("could be expanded if sales exceed capacity") but is worth knowing rather
    /// than assuming: the report counts how often the draw exceeds it.
    var production: String { "PsiNormal(\(Edits.productionMean), \(Edits.productionSigma)) + PsiOutput()" }

    /// 30,000 thousand barrels — the model's own figure, so production's *mean* moves nothing.
    static let productionMean = 30000.0
    static let productionSigma = 2500.0

    /// Barrels produced, `C25`.
    ///
    /// **The option the static model cannot hold.** The case is explicit: the plant has
    /// negligible fixed costs and "SuperChem would only produce Ultra if the market price
    /// exceeds the unit cost". At a single price that sentence does nothing — the plant is on,
    /// or it is off, and the model picks one when somebody types a number into `C4`.
    ///
    /// Under a distribution it is worth real money, because it truncates the loss: a draw
    /// where the received price falls below cost produces **zero**, not a negative margin.
    /// Leaving `C25` as it was would have the plant selling at a loss in every such trial,
    /// which is not what the case describes and not what a plant would do.
    static let barrels = #"IF(AND(C19="Yes", C28>C32), C6, 0) + PsiOutput()"#

    /// Year seven's discounted cash flow, `C48`.
    ///
    /// **This is a defect, not a modelling choice.** `C42` through `C47` carry
    /// `=C$34/((1+C$39)^B4x)`; `C48` carries the number `69276.345961145489`. It is the right
    /// number for the inputs the model was last calculated at, which is exactly why nobody
    /// noticed — a static model can hold a frozen cell indefinitely and still look correct.
    ///
    /// Under simulation it stops being invisible: six years would move with the draw and the
    /// seventh would not, quietly adding a constant to every trial.
    static let yearSeven = "IF(B48=0,0,C$34/((1+C$39)^B48))"

    /// The two outputs, marked for collection.
    ///
    /// `PsiOutput()` contributes nothing to the arithmetic — it is how a Risk Solver model
    /// says "report this cell", and the value is unchanged with or without it.
    static let expectedNPVFormula = #"IF(C19="Yes",C49*C50,C49) + PsiOutput()"#
    static let ratioFormula = "C51/C52 + PsiOutput()"

    /// Barrels, collected so the run can say how often the plant stood idle.
    static let barrelsCell = "C25"
    /// Production, collected so the run can say how often the draw exceeds design capacity.
    static let productionCell = "C6"
    /// The plant's design capacity, which the original model never reads.
    static let capacity = 30000.0

    /// Every edit, as cell → formula.
    var all: [(String, String)] { [
        ("C4", price),
        ("C6", production),
        ("C25", Edits.barrels),
        ("C48", Edits.yearSeven),
        (Edits.expectedNPV, Edits.expectedNPVFormula),
        (Edits.ratio, Edits.ratioFormula),
    ] }
}
