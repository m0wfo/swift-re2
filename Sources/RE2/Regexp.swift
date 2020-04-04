//
//  Regexp.swift
//  
//
//  Created by Chris Mowforth on 04/04/2020.
//

import Foundation

class Regexp {

    enum Op {
        case NO_MATCH // Matches no strings.
        case EMPTY_MATCH // Matches empty string.
        case LITERAL // Matches runes[] sequence
        case CHAR_CLASS // Matches Runes interpreted as range pair list
        case ANY_CHAR_NOT_NL // Matches any character except '\n'
        case ANY_CHAR // Matches any character
        case BEGIN_LINE // Matches empty string at end of line
        case END_LINE // Matches empty string at end of line
        case BEGIN_TEXT // Matches empty string at beginning of text
        case END_TEXT // Matches empty string at end of text
        case WORD_BOUNDARY // Matches word boundary `\b`
        case NO_WORD_BOUNDARY // Matches word non-boundary `\B`
        case CAPTURE // Capturing subexpr with index cap, optional name name
        case STAR // Matches subs[0] zero or more times.
        case PLUS // Matches subs[0] one or more times.
        case QUEST // Matches subs[0] zero or one times.
        case REPEAT // Matches subs[0] [min, max] times; max=-1 => no limit.
        case CONCAT // Matches concatenation of subs[]
        case ALTERNATE // Matches union of subs[]

        // Pseudo ops, used internally by Parser for parsing stack:
        case LEFT_PAREN
        case VERTICAL_BAR

        func isPseudo() -> Bool {
            switch self {
            case .LEFT_PAREN, .VERTICAL_BAR:
                return true
            default:
                return false
            }
        }
    }

    static let EMPTY_SUBS: [Regexp] = []

    var op: Op
    var flags: Int32 = 0
    var subs: [Regexp] = Array()
    var runes: [Int32] = Array()
    var min: Int32 = 0
    var max: Int32 = 0
    var cap: Int32 = 0
    var name: String?
    var namedGroups: [String:Int]?

    init(_ op: Op) {
        self.op = op
    }

    func reinit() {
        self.flags = 0
        self.subs = Regexp.EMPTY_SUBS
        self.runes = Array()
        self.cap = 0
        self.min = 0
        self.max = 0
        self.name = nil
    }
}
