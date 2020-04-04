//
//  Parser.swift
//  
//
//  Created by Chris Mowforth on 04/04/2020.
//

import Foundation

extension String {

    func codePointAt(_ index: Int) -> Int? {
        if index < 0 || index >= self.count {
            return nil
        }

        return Int(Array(self.utf16)[index])
    }

    func charAt(_ index: Int) -> Int? {
        if index < 0 || index >= self.count {
            return nil
        }

        return Int(Array(self.utf8)[index])
    }
}

// StringIterator: a stream of runes with an opaque cursor, permitting
// rewinding.  The units of the cursor are not specified beyond the
// fact that ASCII characters are single width.  (Cursor positions
// could be UTF-8 byte indices, UTF-16 code indices or rune indices.)
//
// In particular, be careful with:
// - skip(int): only use this to advance over ASCII characters
//   since these always have a width of 1.
// - skip(String): only use this to advance over strings which are
//   known to be at the current position, e.g. due to prior call to
//   lookingAt().
// Only use pop() to advance over possibly non-ASCII runes
fileprivate class StringIterator {

    private let str: String
    private var pos: Int = 0

    init(_ str: String) {
        self.str = str
    }

    // Resets the cursor position to a previous value returned by pos().
    func rewindTo(_ pos: Int) {
        self.pos = pos
    }

    // Returns true unless the stream is exhausted.
    func more() -> Bool {
        return pos < str.count
    }

    // Returns the rune at the cursor position.
    // Precondition: |more()|.
    func peek() -> Int {
        return str.codePointAt(pos)!
    }

    // Advances the cursor by |n| positions, which must be ASCII runes.
    //
    // (In practise, this is only ever used to skip over regexp
    // metacharacters that are ASCII, so there is no numeric difference
    // between indices into  UTF-8 bytes, UTF-16 codes and runes.)
    func skip(_ n: Int) {
        pos = pos + n
    }

    // Advances the cursor by the number of cursor positions in |s|
    func skipString(_ s: String) {
        pos = pos + s.count
    }

    // Returns the rune at the cursor position, and advances the cursor
    // past it.  Precondition: |more()|
    func pop() -> Int {
        let r = peek()
        pos = pos + 1 // TODO: adjust dynamically based on code point region
        return r
    }

    // Equivalent to both peek() == c but more efficient because we
    // don't support surrogates.  Precondition: |more()|.
    func lookingAt(_ char: Int) -> Bool {
        return str.charAt(pos) == char
    }

    // Equivalent to rest().startsWith(s).
    func lookingAt(_ s: String) -> Bool {
        return rest().starts(with: s)
    }

    func rest() -> String {
        let startIdx = str.index(str.startIndex, offsetBy: pos)
        let endIndex = str.index(before: str.endIndex)
        return String(str[startIdx...endIndex])
    }

    func from(_ beforePos: Int) -> String {
        let startIdx = str.index(str.startIndex, offsetBy: beforePos)
        let endIndex = str.index(str.startIndex, offsetBy: pos)
        return String(str[startIdx...endIndex])
    }
}

public class PatternSyntaxError: Error {
}

class Parser {

    // Unexpected error
    private static let ERR_INTERNAL_ERROR: String = "regexp/syntax: internal error"

    // Parse errors
    private static let ERR_INVALID_CHAR_CLASS: String = "invalid character class"
    private static let ERR_INVALID_CHAR_RANGE: String = "invalid character class range"
    private static let ERR_INVALID_ESCAPE: String = "invalid escape sequence"
    private static let ERR_INVALID_NAMED_CAPTURE: String = "invalid named capture"
    private static let ERR_INVALID_PERL_OP: String = "invalid or unsupported Perl syntax"
    private static let ERR_INVALID_REPEAT_OP: String = "invalid nested repetition operator"
    private static let ERR_INVALID_REPEAT_SIZE: String = "invalid repeat count"
    private static let ERR_MISSING_BRACKET: String = "missing closing ]"
    private static let ERR_MISSING_PAREN: String = "missing closing )"
    private static let ERR_MISSING_REPEAT_ARGUMENT: String =
        "missing argument to repetition operator"
    private static let ERR_TRAILING_BACKSLASH: String = "trailing backslash at end of expression"
    private static let ERR_DUPLICATE_NAMED_CAPTURE: String = "duplicate capture group name"


    private let wholeRegexp: String
    // Flags control the behavior of the parser and record information about
    // regexp context.
    private var flags: Int32
    // Stack of parsed expressions.
    private var stack: [Regexp] = Array()
    private var free: Regexp? = nil
    private var numCap: Int = 0 // number of capturing groups seen
    private var namedGroups: [String:Int] = Dictionary()

    init(wholeRegexp: String, flags: Int32) {
        self.wholeRegexp = wholeRegexp
        self.flags = flags
    }

    private func newRegexp(_ op: Regexp.Op) -> Regexp {
        if let currentFree = free {
            if !currentFree.subs.isEmpty {
                free = currentFree.subs[0]
                free!.reinit()
                free!.op = op
            }
        } else {
            free = Regexp(op)
        }
        return free!
    }

    private func reuse(_ re: Regexp) {
        if !re.subs.isEmpty {
            re.subs[0] = free!
        }
        free = re
    }

    // MARK: Parse stack manipulation.

    private func pop() -> Regexp? {
        return stack.popLast()
    }

    private func popToPseudo() -> [Regexp] {
        let n = stack.count
        var i = n
        repeat {
            i = i - 1
        } while i > 0 && stack[i - 1].op.isPseudo()
        let r = Array(stack[i...n])
        stack.removeSubrange(i..<n)
        return r
    }

    // push pushes the regexp re onto the parse stack and returns the regexp.
    // Returns null for a CHAR_CLASS that can be merged with the top-of-stack.
    private func push(_ re: Regexp) -> Regexp? {
        if re.op == Regexp.Op.CHAR_CLASS && re.runes.count == 2 && re.runes[0] == re.runes[1] {
            if maybeConcat(r: re.runes[0], flags: re.flags & ~RE2.FOLD_CASE) {
                return nil
            }
            re.op = Regexp.Op.LITERAL
            re.runes = [re.runes[0]]
            re.flags = flags & ~RE2.FOLD_CASE
        } else if (re.op == Regexp.Op.CHAR_CLASS
            && re.runes.count == 4
            && re.runes[0] == re.runes[1]
            && re.runes[2] == re.runes[3]
            && Unicode.simpleFold(re.runes[0]) == re.runes[2]
            && Unicode.simpleFold(re.runes[2]) == re.runes[0])
            || (re.op == Regexp.Op.CHAR_CLASS
                && re.runes.count == 2
            && re.runes[0] + 1 == re.runes[1]
            && Unicode.simpleFold(re.runes[0]) == re.runes[1]
            && Unicode.simpleFold(re.runes[1]) == re.runes[0]) {

            // Case-insensitive rune like [Aa] or [Δδ]
            if maybeConcat(r: re.runes[0], flags: flags | RE2.FOLD_CASE) {
                return nil
            }

            // Rewrite as (case-insensitive) literal
            re.op = Regexp.Op.LITERAL
            re.runes = [re.runes[0]]
            re.flags = flags | RE2.FOLD_CASE
        } else {
            // Incremental concatenation
            maybeConcat(r: -1, flags: 0)
        }
        stack.append(re)
        return re
    }

    // maybeConcat implements incremental concatenation
    // of literal runes into string nodes.  The parser calls this
    // before each push, so only the top fragment of the stack
    // might need processing.  Since this is called before a push,
    // the topmost literal is no longer subject to operators like *
    // (Otherwise ab* would turn into (ab)*.)
    // If (r >= 0 and there's a node left over, maybeConcat uses it
    // to push r with the given flags.
    // maybeConcat reports whether r was pushed.
    private func maybeConcat(r: Int32, flags: Int32) -> Bool {
        let n = stack.count
        if n < 2 {
            return false
        }
        let re1 = stack[n-1]
        let re2 = stack[n-2]
        if re1.op != Regexp.Op.LITERAL
            || re2.op != Regexp.Op.LITERAL
            || (re1.flags & RE2.FOLD_CASE) != (re2.flags & RE2.FOLD_CASE) {
            return false
        }

        // Push re1 into re2
        re2.runes = re2.runes + re1.runes

        // Reuse re1 if possible
        if r > 0 {
            re1.runes = [r]
            re1.flags = flags
            return true
        }

        pop()
        reuse(re1)
        return false // did not push r
    }

    private func newLiteral(r: Int32, flags: Int32) -> Regexp {
        var tmp = r
        let re = Regexp(Regexp.Op.LITERAL)
        re.flags = flags
        if flags & RE2.FOLD_CASE != 0 {
            tmp = Parser.minFoldRune(r)
        }
        re.runes = [tmp]
        return re
    }

    private static func minFoldRune(_ r: Int32) -> Int32 {
        if r < Unicode.MIN_FOLD || r > Unicode.MAX_FOLD {
            return r
        }

        var min = r
        let r0 = r
        var tmp = r
        repeat {
            tmp = Unicode.simpleFold(tmp)
            if tmp == r0 {
                break
            }
            tmp = Unicode.simpleFold(tmp)
            if min > r {
                min = r
            }
        } while true
        return min
    }

    // literal pushes a literal regexp for the rune r on the stack
    // and returns that regexp
    private func literal(_ r: Int32) {
        push(newLiteral(r: r, flags: flags))
    }

    // op pushes a regexp with the given op onto the stack
    // and returns that regexp
    private func op(_ op: Regexp.Op) -> Regexp {
        let re = Regexp(op)
        re.flags = flags
        return push(re)!
    }

    // repeat replaces the top stack element with itself repeated according to
    // op, min, max.  beforePos is the start position of the repetition operator.
    // Pre: t is positioned after the initial repetition operator.
    // Post: t advances past an optional perl-mode '?', or stays put.
    //       Or, it fails with PatternSyntaxException
    private func repeatR(op: Regexp.Op, min: Int, max: Int, beforePos: Int, t: StringIterator, lastRepeatPos: Int) throws {
        var flags = self.flags
        if (flags & RE2.PERL_X) != 0 {
            if t.more() && t.lookingAt("?") {
                t.skip(1)
                flags ^= RE2.NON_GREEDY
            }
            if lastRepeatPos != -1 {
                // In Perl it is not allowed to stack repetition operators:
                // a** is a syntax error, not a doubled star, and a++ means
                // something else entirely, which we don't support!
                throw PatternSyntaxError()
            }
        }
        let n = stack.count
        if n == 0 {
            throw PatternSyntaxError()
        }

    }
}
