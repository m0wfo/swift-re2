class RE2 {

    // MARK: Parser flags.

    // Fold case during matching (case-insensitive).
    static let FOLD_CASE: Int32 = 0x01

    // Treat pattern as a literal string instead of a regexp.
    static let LITERAL: Int32 = 0x02

    // Allow character classes like [^a-z] and [[:space:]] to match newline.
    static let CLASS_NL: Int32 = 0x04

    // Allow '.' to match newline.
    static let DOT_NL: Int32 = 0x08

    // Treat ^ and $ as only matching at beginning and end of text, not
    // around embedded newlines.  (Perl's default).
    static let ONE_LINE: Int32 = 0x10

    // Make repetition operators default to non-greedy.
    static let NON_GREEDY: Int32 = 0x20

    // allow Perl extensions:
    //   non-capturing parens - (?: )
    //   non-greedy operators - *? +? ?? {}?
    //   flag edits - (?i) (?-i) (?i: )
    //     i - FoldCase
    //     m - !OneLine
    //     s - DotNL
    //     U - NonGreedy
    //   line ends: \A \z
    //   \Q and \E to disable/enable metacharacters
    //   (?P<name>expr) for named captures
    // \C (any byte) is not supported.
    static let PERL_X: Int32 = 0x40

    // Allow \p{Han}, \P{Han} for Unicode group and negation.
    static let UNICODE_GROUPS: Int32 = 0x80

    // Regexp END_TEXT was $, not \z.  Internal use only.
    static let WAS_DOLLAR: Int32 = 0x100

    static let MATCH_NL = CLASS_NL | DOT_NL

    // As close to Perl as possible.
    static let PERL = CLASS_NL | ONE_LINE | PERL_X | UNICODE_GROUPS

    // POSIX syntax.
    static let POSIX: Int32 = 0

    // Anchors
    static let UNANCHORED = 0
    static let ANCHOR_START = 1
    static let ANCHOR_BOTH = 2

    // MARK: Instance members

    private let expr: String // as passed to Compile
    private let prog: Prog // compiled program
    private let cond: Int32  // EMPTY_* bitmask: empty-width conditions
    private let numSubExp: Int32 // required at start of match
    private var longest: Bool

    var prefix: String? // required UTF-16 prefix in unanchored matches
    var prefixUTF8: [UInt8] = Array() // required UTF-8 prefix in unanchored matches
    var prefixComplete: Bool? // true iff prefix is the entire regexp
    var prefixRune: Int32? // first rune in prefix

    init(expr: String, prog: Prog, numSubexp: Int32, longest: Bool) {
        self.expr = expr
        self.prog = prog
        self.numSubExp = numSubexp
        self.cond = prog.startCond()
        self.longest = longest
    }
}
