import Foundation

/// The words a retry changed: the first pass and the retried text aligned on the longest
/// run of words they share, with case and punctuation set aside so a new comma or capital is
/// no change. Each stretch between shared words is one change; within it, words are counted
/// as replaced pairwise and the rest as added or removed.
public struct WordDiff: Sendable, Equatable {
    /// One stretch of differing words, as written: `before` became `after`. Either can be
    /// empty, for words the retry added or removed.
    public struct Change: Sendable, Equatable {
        public var before: [String]
        public var after: [String]

        public init(before: [String], after: [String]) {
            self.before = before
            self.after = after
        }
    }

    public var changes: [Change] = []
    public var replaced = 0
    public var added = 0
    public var removed = 0

    public var isEmpty: Bool { changes.isEmpty }

    public init(_ before: String, _ after: String) {
        let a = Self.words(before), b = Self.words(after)
        let x = a.map(Self.key), y = b.map(Self.key)
        // shared[i][j]: the most words x[i...] and y[j...] have in common, in order.
        var shared = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                shared[i][j] = x[i] == y[j] ? shared[i + 1][j + 1] + 1 : max(shared[i + 1][j], shared[i][j + 1])
            }
        }
        var i = 0, j = 0
        var open = Change(before: [], after: [])
        var changes: [Change] = []
        func close() {
            guard !open.before.isEmpty || !open.after.isEmpty else { return }
            changes.append(open)
            open = Change(before: [], after: [])
        }
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                close()
                i += 1
                j += 1
            } else if j == y.count || (i < x.count && shared[i + 1][j] >= shared[i][j + 1]) {
                open.before.append(a[i])
                i += 1
            } else {
                open.after.append(b[j])
                j += 1
            }
        }
        close()
        self.changes = changes
        for change in changes {
            let pairs = min(change.before.count, change.after.count)
            replaced += pairs
            removed += change.before.count - pairs
            added += change.after.count - pairs
        }
    }

    /// Words as written: runs of letters, digits and apostrophes, without apostrophes at
    /// either end, so quotes and punctuation fall away.
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            let word = current.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
            if !word.isEmpty { words.append(word) }
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// What two words are compared by: case and the kind of apostrophe set aside.
    static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }
}
