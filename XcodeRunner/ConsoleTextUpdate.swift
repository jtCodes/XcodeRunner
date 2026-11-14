import Foundation

/// UTF-16 offsets match NSTextStorage's indexing, including emoji and Unicode.
struct ConsoleTextUpdate {
    var removedPrefix: Int
    var appended: String
    var replacesAll: Bool

    static func between(_ previous: String, and next: String) -> Self {
        let old = previous as NSString
        let new = next as NSString
        if new.hasPrefix(previous) {
            return Self(removedPrefix: 0, appended: new.substring(from: old.length), replacesAll: false)
        }
        // The session retains a bounded tail. Preserve its overlapping text and
        // remove only the expired prefix rather than rebuilding the text storage.
        if !next.isEmpty {
            let anchor = String(next.prefix(256))
            let match = old.range(of: anchor)
            if match.location != NSNotFound {
                let overlap = old.length - match.location
                if overlap <= new.length && new.hasPrefix(old.substring(from: match.location)) {
                    return Self(removedPrefix: match.location, appended: new.substring(from: overlap), replacesAll: false)
                }
            }
        }
        return Self(removedPrefix: old.length, appended: next, replacesAll: true)
    }
}
