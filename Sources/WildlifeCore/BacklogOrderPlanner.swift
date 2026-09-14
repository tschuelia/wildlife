import Foundation

public enum BacklogOrderPlanner {
    /// Returns a unique key order with `key` immediately before `targetKey`.
    /// A missing target means the end of the list, which also supports inserting
    /// a session that is not yet in the backlog.
    public static func moving(
        _ key: String,
        before targetKey: String?,
        in orderedKeys: [String]
    ) -> [String] {
        guard targetKey != key else { return orderedKeys }
        var seen = Set<String>()
        var result = orderedKeys.filter { candidate in
            candidate != key && seen.insert(candidate).inserted
        }
        let insertionIndex = targetKey
            .flatMap { target in result.firstIndex(of: target) }
            ?? result.endIndex
        result.insert(key, at: insertionIndex)
        return result
    }
}
