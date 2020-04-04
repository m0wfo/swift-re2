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

public enum PatternSyntaxError: Error {
    case invalidRepeatOp
    case missingRepeatArgument
}

class Parser {

//    // Unexpected error
//    private static let ERR_INTERNAL_ERROR: String = "regexp/syntax: internal error"
//
//    // Parse errors
//    static let ERR_INVALID_CHAR_CLASS: String = "invalid character class"
//    static let ERR_INVALID_CHAR_RANGE: String = "invalid character class range"
//    private static let ERR_INVALID_ESCAPE: String = "invalid escape sequence"
//    private static let ERR_INVALID_NAMED_CAPTURE: String = "invalid named capture"
//    private static let ERR_INVALID_PERL_OP: String = "invalid or unsupported Perl syntax"
//    static let ERR_INVALID_REPEAT_OP: String = "invalid nested repetition operator"
//    private static let ERR_INVALID_REPEAT_SIZE: String = "invalid repeat count"
//    private static let ERR_MISSING_BRACKET: String = "missing closing ]"
//    private static let ERR_MISSING_PAREN: String = "missing closing )"
//    private static let ERR_MISSING_REPEAT_ARGUMENT: String =
//        "missing argument to repetition operator"
//    private static let ERR_TRAILING_BACKSLASH: String = "trailing backslash at end of expression"
//    private static let ERR_DUPLICATE_NAMED_CAPTURE: String = "duplicate capture group name"


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
        stack.removeSubrange(i...n)
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
    private func repeatR(op: Regexp.Op, min: Int32, max: Int32, beforePos: Int, t: StringIterator, lastRepeatPos: Int) throws {
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
                throw PatternSyntaxError.invalidRepeatOp
            }
        }
        let n = stack.count
        if n == 0 {
            throw PatternSyntaxError.missingRepeatArgument
        }
        let sub = stack[n - 1]
        if sub.op.isPseudo() {
            throw PatternSyntaxError.missingRepeatArgument
        }
        let re = newRegexp(op)
        re.min = min
        re.max = max
        re.flags = flags
        re.subs = [sub]
        stack[n - 1] = re
    }

    // concat replaces the top of the stack (above the topmost '|' or '(') with
    // its concatenation.
    private func concat() -> Regexp {
        maybeConcat(r: -1, flags: 0)

        // Scan down to find pseudo-operator | or (.
        let subs = popToPseudo()

        // Empty concatenation is special case.
        if subs.isEmpty {
            return push(newRegexp(Regexp.Op.EMPTY_MATCH))!
        }

        return push(collapse(subs, op: Regexp.Op.CONCAT))!
    }

    // TODO
    // alternate()
    // cleanAlt()

    // collapse returns the result of applying op to subs[start:end].
    // If (sub contains op nodes, they all get hoisted up
    // so that there is never a concat of a concat or an
    // alternate of an alternate.
    private func collapse(_ subs: [Regexp], op: Regexp.Op) -> Regexp {
        if subs.count == 1 {
            return subs[0]
        }

        // Concatenate subs iff op is same.
        // Compute length in first pass.
        var len = 0
        for sub in subs {
            len += (sub.op == op) ? sub.subs.count : 1
        }
        var newSubs: [Regexp] = Array()
        var i = 0
        for sub in subs {
            if sub.op == op {
                newSubs += subs[0...i]
                i = i + sub.subs.count
                reuse(sub)
            } else {
                newSubs[i+1] = sub
            }
        }

        var re = newRegexp(op)
        re.subs = newSubs

        if op == Regexp.Op.ALTERNATE {
            re.subs = factor(&re.subs, re.flags)
            if re.subs.count == 1 {
                let old = re
                re = re.subs[0]
                reuse(old)
            }
        }

        return re
    }

    // factor factors common prefixes from the alternation list sub.  It
    // returns a replacement list that reuses the same storage and frees
    // (passes to p.reuse) any removed *Regexps.
    //
    // For example,
    //     ABC|ABD|AEF|BCX|BCY
    // simplifies by literal prefix extraction to
    //     A(B(C|D)|EF)|BC(X|Y)
    // which simplifies by character class introduction to
    //     A(B[CD]|EF)|BC[XY]
    //
    private func factor(_ exprs: inout [Regexp], _ flags: Int32) -> [Regexp] {
        if exprs.count < 2 {
            return exprs
        }

        // Swift's Array Slices are more akin to Go's slices, so
        // we deviate from the Java implementation somewhat in this next bit
        var s = 0
        var lensub = exprs.count
        var lenout = 0

        // Round 1: Factor out common literal prefixes.
        // Note: (str, strlen) and (istr, istrlen) are like Go slices
        // onto a prefix of some Regexp's runes array (hence offset=0).
        var str: [Int32]? = nil
        var strlen = 0
        var strflags: Int32 = 0
        var start = 0

        var i = 0
        repeat {
            // Invariant: the Regexps that were in sub[0:start] have been
            // used or marked for reuse, and the slice space has been reused
            // for out (len <= start).
            //
            // Invariant: sub[start:i] consists of regexps that all begin
            // with str as modified by strflags.
            var istr: [Int32]? = nil
            var istrlen = 0
            var iflags: Int32 = 0

            if i < lensub {
                var re = exprs[s + i]
                if re.op == Regexp.Op.CONCAT && re.subs.count > 0 {
                    re = re.subs[0]
                }
                if re.op == Regexp.Op.LITERAL {
                    istr = re.runes
                    istrlen = re.runes.count
                    iflags = re.flags & RE2.FOLD_CASE
                }

                // istr is the leading literal string that re begins with.
                // The string refers to storage in re or its children.
                if iflags == strflags {
                    var same = 0
                    repeat {
                        same += 1
                    } while same < strlen && same < istrlen && str![same] == istr![same]
                    if same > 0 {
                        // Matches at least one rune in current range.
                        // Keep going around.
                        strlen = same
                        continue
                    }
                }
            }

            // Found end of a run with common leading literal string:
            // sub[start:i] all begin with str[0:strlen], but sub[i]
            // does not even begin with str[0].
            //
            // Factor out common string and append factored expression to out.
            if i == start {
                // Nothing to do - run of length 0.
            } else if i == start + 1 {
                // Just one: don't bother factoring.
                lenout += 1
                exprs[lenout] = exprs[s + start]
            } else {
                // Construct factored form: prefix(suffix1|suffix2|...)
                let prefix = newRegexp(Regexp.Op.LITERAL)
                prefix.flags = strflags
                prefix.runes = Array(str![0...strlen])

                var j = start
                repeat {
                    exprs[s + j] = removeLeadingString(&exprs[s + j], strlen)
                    j += 1
                } while j < i

                // Recurse.
                let suffix = collapse(Array(exprs[s+start...s+i]), op: Regexp.Op.ALTERNATE)
                let re = newRegexp(Regexp.Op.CONCAT)
                re.subs = [prefix, suffix]
                lenout += 1
                exprs[lenout] = re
            }

            // Prepare for next iteration.
            start = i
            str = istr
            strlen = istrlen
            strflags = iflags

            i += 1
        } while i <= lensub

        lensub = lenout
        s = 0

        // Round 2: Factor out common complex prefixes,
        // just the first piece of each concatenation,
        // whatever it is.  This is good enough a lot of the time.
        start = 0
        lenout = 0
        var first: Regexp? = nil

        i = 0
        repeat {
            // Invariant: the Regexps that were in sub[0:start] have been
            // used or marked for reuse, and the slice space has been reused
            // for out (lenout <= start).
            //
            // Invariant: sub[start:i] consists of regexps that all begin with
            // ifirst.
            var ifirst: Regexp? = nil
            if i < lensub {
                ifirst = leadingRegexp(exprs[s + i])
                if first != nil && ifirst != nil {
                    if first == ifirst {
                        continue
                    }
                }
            }

            // Found end of a run with common leading regexp:
            // sub[start:i] all begin with first but sub[i] does not.
            //
            // Factor out common regexp and append factored expression to out.
            if i == start {
                // Nothing to do - run of length 0
            } else if i == start + 1 {
                lenout += 1
                // Just one: don't bother factoring.
                exprs[lenout] = exprs[s + start]
            } else {
                // Construct factored form: prefix(suffix1|suffix2|...)
                let prefix = first
                repeat {

                }
            }

            // Prepare for next iteration.
            start = i
            first = ifirst

            i += 1
        } while i < lensub
    }

    // removeLeadingString removes the first n leading runes
    // from the beginning of re.  It returns the replacement for re.
    private func removeLeadingString(_ re: inout Regexp, _ n: Int) -> Regexp {
        if re.op == Regexp.Op.CONCAT && !re.subs.isEmpty {
            // Removing a leading string in a concatenation
            // might simplify the concatenation.
            let sub = removeLeadingString(&re.subs[0], n)
            re.subs[0] = sub
            if sub.op == Regexp.Op.EMPTY_MATCH {
                reuse(sub)
                switch re.subs.count {
                case 0:
                    break
                case 1:
                    // Impossible but handle.
                    re.op = Regexp.Op.EMPTY_MATCH
                    break
                case 2:
                    do {
                        let old = re
                        re = re.subs[1]
                        reuse(old)
                        break
                    }
                default:
                    re.subs = Array(re.subs[1..<re.subs.count])
                    break
                }
            }
        }
        return re
    }

    // leadingRegexp returns the leading regexp that re begins with.
    // The regexp refers to storage in re or its children
    private func leadingRegexp(_ re: Regexp) -> Regexp? {
        if re.op == Regexp.Op.EMPTY_MATCH {
            return nil
        }

        if re.op == Regexp.Op.CONCAT && re.subs.count > 0 {
            let sub = re.subs[0]
            if sub.op == Regexp.Op.EMPTY_MATCH {
                return nil
            }
            return sub
        }
        return re
    }
}
