import Foundation
import SwiftExcelCore
import SwiftExcelFunctions
import BusinessMath

/// What the run found, in the terms the case asks its question in.
struct Report {
    /// The model exactly as it was found: price 45, the frozen year seven, no shutdown option.
    let asFound: (npv: Double, ratio: Double)
    /// The same model at the distributions' means, defect fixed, option in place. Everything
    /// the simulation changes **except the uncertainty**.
    let atMean: (npv: Double, ratio: Double)
    let npv: SimulationResults
    let ratio: SimulationResults
    /// Barrels produced each trial — zero on the trials where the plant stood idle.
    let barrels: SimulationResults?
    /// Production drawn each trial, against a design capacity the model never reads.
    let production: SimulationResults?
    let trials: Int
    let seed: UInt64
    let sheet: CellSheet

    /// How often the received price fell below cost and the plant produced nothing.
    ///
    /// The case's sentence — "SuperChem would only produce Ultra if the market price exceeds
    /// the unit cost" — does nothing at a single price. This is what it is worth.
    var probabilityIdle: Double {
        guard let barrels else { return .nan }
        return barrels.probabilityBelow(1)
    }

    /// How often the draw asks the plant for more than it was designed to make.
    var probabilityOverCapacity: Double {
        guard let production else { return .nan }
        return production.probabilityAbove(Edits.capacity)
    }

    /// The hurdle the case sets: a program must return five times its R&D spend.
    static let hurdle = 5.0

    /// How often the project clears the hurdle it is actually judged against.
    var probabilityOfClearingHurdle: Double { ratio.probabilityAbove(Self.hurdle) }

    /// How often the expected NPV is positive at all.
    var probabilityPositive: Double { npv.probabilityAbove(0) }

    /// **What the retyped price assumption is worth**, on its own.
    ///
    /// `C4` was `45` and the distribution's mean is `47.5`. That is a change of assumption,
    /// not a consequence of simulating, and it moves the answer more than the uncertainty
    /// does. Reporting `asFound → simulated` as one number would credit the simulation for it.
    var assumptionMove: Double { atMean.ratio - asFound.ratio }

    /// **What the uncertainty itself is worth.**
    ///
    /// A static model computes the answer *at* the mean; a simulation computes the *mean of*
    /// the answers. They agree only when the model is linear in its uncertain inputs, and this
    /// one is not: the shutdown option makes it kinked, and revenue is a product of two
    /// uncertain quantities. The difference is the part only a simulation can find.
    var uncertaintyMove: Double { ratio.statistics.mean - atMean.ratio }

    var console: String {
        """

        ── Superchem, Ultra ─────────────────────────────────────────────
        trials \(trials), seed \(seed)

        Expected NPV ($000s)
          as found          \(ModelSimulation.format(asFound.npv))
          at the means      \(ModelSimulation.format(atMean.npv))
          simulated mean    \(ModelSimulation.format(npv.statistics.mean))
          median            \(ModelSimulation.format(npv.statistics.median))
          5th – 95th        \(ModelSimulation.format(npv.percentiles.p5)) – \(ModelSimulation.format(npv.percentiles.p95))
          P(NPV > 0)        \(percent(probabilityPositive))

        Expected NPV / R&D  (hurdle \(ModelSimulation.format(Self.hurdle))×)
          as found          \(ModelSimulation.format(asFound.ratio))×
          at the means      \(ModelSimulation.format(atMean.ratio))×   (+\(ModelSimulation.format(assumptionMove)) from the price assumption)
          simulated mean    \(ModelSimulation.format(ratio.statistics.mean))×   (+\(ModelSimulation.format(uncertaintyMove)) from the uncertainty)
          median            \(ModelSimulation.format(ratio.statistics.median))×
          5th – 95th        \(ModelSimulation.format(ratio.percentiles.p5))× – \(ModelSimulation.format(ratio.percentiles.p95))×
          P(clears 5×)      \(percent(probabilityOfClearingHurdle))

        What only a distribution shows
          P(plant idle)     \(percent(probabilityIdle))   price below cost, so it makes nothing
          P(over capacity)  \(percent(probabilityOverCapacity))   and the model never checks C12
        ─────────────────────────────────────────────────────────────────
        """
    }

    func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }
}
