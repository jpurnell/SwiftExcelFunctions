import Foundation
import SwiftExcelCore

/// `BAHTTEXT(number)` — a number spelled out in Thai, as currency.
///
/// The only function in the text family that spells rather than transforms, and the rules
/// are Thai grammar rather than string handling. Four of them are not digit substitution:
///
/// | Rule | Example |
/// |---|---|
/// | A units `1` after any higher digit is **เอ็ด**, not หนึ่ง | 11 → สิบเอ็ด |
/// | A tens `1` is bare **สิบ** — no หนึ่ง before it | 10 → สิบ |
/// | A tens `2` is **ยี่สิบ**, not สองสิบ | 20 → ยี่สิบ |
/// | A whole number takes **ถ้วน** ("exactly") where satang would go | 100 → …บาทถ้วน |
///
/// Values of a million and above recurse on **ล้าน**, which is why 1,000,000 is not simply
/// the next place name in the ladder: Thai counts in units of a million rather than
/// continuing to a distinct word for ten million.
///
/// ```swift
/// var registry = FunctionRegistry()
/// registry.register(BuiltinBahtText.bahtText)
/// ```
public enum BuiltinBahtText {

    /// The function for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [bahtText]

    /// `BAHTTEXT(number)` — the number in Thai words, suffixed บาท and สตางค์.
    public static let bahtText = ExcelFunction(name: "BAHTTEXT", minArgs: 1, maxArgs: 1) { args in
        guard case .number(let value) = args[0].resolved else {
            if case .error(let error) = args[0].resolved { return .error(error) }
            if case .blank = args[0].resolved { return .text(spell(0)) }
            return .error(.value)
        }
        guard value.isFinite else { return .error(.value) }
        return .text(spell(value))
    }

    // MARK: - Spelling

    static let digits = ["ศูนย์", "หนึ่ง", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด", "เก้า"]
    static let places = ["", "สิบ", "ร้อย", "พัน", "หมื่น", "แสน"]

    /// Spells a currency amount, rounded to the satang.
    ///
    /// - Parameter value: The amount in baht.
    /// - Returns: The Thai spelling, including the บาท and สตางค์ or ถ้วน suffixes.
    static func spell(_ value: Double) -> String {
        let negative = value < 0
        // Rounded to the satang first: spelling an unrounded value would put a fraction of
        // a satang into words that cannot express it.
        let totalSatang = (abs(value) * 100).rounded()
        guard totalSatang.isFinite else { return "" }
        let baht = Int(totalSatang / 100)
        let satang = Int(totalSatang.truncatingRemainder(dividingBy: 100))

        var text = integer(baht) + "บาท"
        // **ถ้วน means "exactly"**, and replaces the satang clause rather than joining it.
        text += satang == 0 ? "ถ้วน" : integer(satang) + "สตางค์"
        return negative ? "ลบ" + text : text
    }

    /// Spells a non-negative integer.
    ///
    /// - Parameter value: The integer to spell.
    /// - Returns: Its Thai words.
    static func integer(_ value: Int) -> String {
        guard value != 0 else { return digits[0] }
        guard value < 1_000_000 else {
            // Thai counts in millions rather than naming a place beyond แสน, so both halves
            // are spelled by the same rules and joined by ล้าน.
            let millions = value / 1_000_000
            let rest = value % 1_000_000
            return integer(millions) + "ล้าน" + (rest > 0 ? integer(rest) : "")
        }
        return group(value)
    }

    /// Spells a value below one million, where the place ladder applies directly.
    ///
    /// - Parameter value: The value, `1..<1_000_000`.
    /// - Returns: Its Thai words.
    static func group(_ value: Int) -> String {
        let characters = Array(String(value))
        var words = ""
        for (offset, character) in characters.enumerated() {
            guard let digit = character.wholeNumberValue, digit != 0 else { continue }
            let place = characters.count - offset - 1
            switch (place, digit) {
            case (0, 1) where characters.count > 1:
                words += "เอ็ด"
            case (1, 1):
                words += "สิบ"
            case (1, 2):
                words += "ยี่สิบ"
            default:
                words += digits[digit] + places[place]
            }
        }
        return words
    }
}
