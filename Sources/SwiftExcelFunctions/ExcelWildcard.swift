import Foundation

/// Excel's two wildcards, and the tilde that turns them off.
///
/// `COUNTIF(A:A, "*")` counts the cells holding text — *any* text — and is how a spreadsheet
/// asks "how many of these are filled in". Without wildcards it counts the cells whose
/// contents are literally one asterisk, which in a real workbook is none:
///
/// ```
/// COUNTIFS(volunteers, "*")     38 in Excel, 0 without this
/// ```
///
/// That formula was the last stale-value finding in one corpus after three others were
/// fixed, and it was ours rather than the workbook's.
///
/// | Pattern | Matches |
/// |---|---|
/// | `*` | any run of characters, including none |
/// | `?` | exactly one character |
/// | `~*`, `~?`, `~~` | a literal asterisk, question mark, or tilde |
///
/// Matching is case-insensitive, as every text comparison in Excel is.
enum ExcelWildcard {

    /// Whether a pattern contains a wildcard at all.
    ///
    /// Worth asking before matching: the overwhelming majority of criteria are plain text,
    /// and a plain comparison is both faster and exactly right for them.
    ///
    /// - Parameter pattern: The criterion as written.
    /// - Returns: `true` when an unescaped `*` or `?` appears.
    static func isPattern(_ pattern: String) -> Bool {
        var escaped = false
        for character in pattern {
            if escaped { escaped = false; continue }
            if character == "~" { escaped = true; continue }
            if character == "*" || character == "?" { return true }
        }
        return false
    }

    /// Whether text matches a pattern, from end to end.
    ///
    /// Anchored at both ends, which is what `COUNTIF` means by a criterion: `"a*"` matches
    /// text beginning with an `a`, and `"a"` matches only an `a`. `SEARCH`'s wildcards are
    /// the unanchored version of the same thing and are not this function.
    ///
    /// - Parameters:
    ///   - text: The cell's text.
    ///   - pattern: The criterion.
    /// - Returns: `true` when the whole of `text` matches the whole of `pattern`.
    static func matches(_ text: String, pattern: String) -> Bool {
        let subject = Array(text.lowercased())
        let tokens = parse(pattern.lowercased())

        // The classic two-pointer walk with one backtrack point, which is linear in
        // practice and needs no recursion: `star` remembers where the last `*` was and
        // `retry` how much of the subject it had consumed, so a dead end resumes there
        // with the star swallowing one more character.
        var subjectIndex = 0
        var tokenIndex = 0
        var star: Int?
        var retry = 0

        while subjectIndex < subject.count {
            if tokenIndex < tokens.count, matchesOne(tokens[tokenIndex], subject[subjectIndex]) {
                subjectIndex += 1
                tokenIndex += 1
            } else if tokenIndex < tokens.count, case .anyRun = tokens[tokenIndex] {
                star = tokenIndex
                retry = subjectIndex
                tokenIndex += 1
            } else if let lastStar = star {
                tokenIndex = lastStar + 1
                retry += 1
                subjectIndex = retry
            } else {
                return false
            }
        }
        // Trailing stars match nothing, which is still a match.
        while tokenIndex < tokens.count, case .anyRun = tokens[tokenIndex] { tokenIndex += 1 }
        return tokenIndex == tokens.count
    }

    /// One element of a pattern.
    private enum Token {
        /// `*` — any run of characters, including none.
        case anyRun
        /// `?` — exactly one character.
        case anyOne
        /// A character that must appear as itself.
        case literal(Character)
    }

    /// Whether one token accepts one character.
    private static func matchesOne(_ token: Token, _ character: Character) -> Bool {
        switch token {
        case .anyRun: return false          // handled by the caller, which needs to backtrack
        case .anyOne: return true
        case .literal(let expected): return expected == character
        }
    }

    /// Splits a pattern into tokens, honouring the tilde.
    ///
    /// A trailing tilde with nothing after it is a literal tilde rather than an error:
    /// Excel accepts the criterion and so does this.
    ///
    /// - Parameter pattern: The pattern, already lowercased.
    /// - Returns: Its tokens, in order.
    private static func parse(_ pattern: String) -> [Token] {
        var tokens: [Token] = []
        var escaped = false
        for character in pattern {
            if escaped {
                tokens.append(.literal(character))
                escaped = false
                continue
            }
            switch character {
            case "~": escaped = true
            case "*": tokens.append(.anyRun)
            case "?": tokens.append(.anyOne)
            default: tokens.append(.literal(character))
            }
        }
        if escaped { tokens.append(.literal("~")) }
        return tokens
    }
}
