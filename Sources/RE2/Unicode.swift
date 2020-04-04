//
//  Unicode.swift
//  
//
//  Created by Chris Mowforth on 04/04/2020.
//

import Foundation

final class Unicode {

    static let MIN_FOLD: Int32 = 0x0041
    static let MAX_FOLD: Int32 = 0x1044f

    // simpleFold iterates over Unicode code points equivalent under
    // the Unicode-defined simple case folding.  Among the code points
    // equivalent to rune (including rune itself), SimpleFold returns the
    // smallest r >= rune if one exists, or else the smallest r >= 0.
    //
    // For example:
    //      SimpleFold('A') = 'a'
    //      SimpleFold('a') = 'A'
    //
    //      SimpleFold('K') = 'k'
    //      SimpleFold('k') = '\u212A' (Kelvin symbol, K)
    //      SimpleFold('\u212A') = 'K'
    //
    //      SimpleFold('1') = '1'
    //
    // Derived from Go's unicode.SimpleFold.
    //
    static func simpleFold(_ r: Int32) -> Int32 {
        // Consult caseOrbit table for special cases
        var lo = 0
        var hi = UnicodeTables.CASE_ORBIT.count
        repeat {
            let m = lo + (hi - lo) / 2
            if UnicodeTables.CASE_ORBIT[m][0] < r {
                lo = m + 1
            } else {
                hi = m
            }
        } while lo < hi

        if lo < UnicodeTables.CASE_ORBIT.count && UnicodeTables.CASE_ORBIT[lo][0] == r {
            return UnicodeTables.CASE_ORBIT[lo][1]
        }

        // No folding specified. This is a one- or two-element
        // equivalence class containing rune and toLower(rune)
        // and toUpper(rune) if they are different from rune
        let char = String(UnicodeScalar(Int(r))!)
        if char != char.lowercased() {
            return r
        }

        return Int32(char.uppercased())!
    }
}
