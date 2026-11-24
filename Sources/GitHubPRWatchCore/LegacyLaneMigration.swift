import Foundation

/// Rewrites lane conditions in a `views.json` saved by a build with the old lanes, so it
/// decodes with today's lanes. The old lanes were a viewer-dependent first lane, CI running,
/// In merge queue, and Waiting on others.
///
/// - `inMergeQueue` becomes `mergeQueue`, `waiting` becomes `inReview`, `ciRunning` stays
///   (`Lane.migrating`).
/// - The old first lane depended on who was looking and has no equivalent, so its name, like
///   any name with no lane today, is removed from the condition's list.
/// - A condition left with no lanes is dropped from its group, with any `not` around it,
///   rather than kept as a rule that matches nothing (or, negated, everything). In the usual
///   "all" group that means the view shows more, never an empty view.
/// - A group emptied that way matches everything, whatever its match was before, because an
///   empty "any" group would otherwise match nothing.
///
/// Files without old lane names come back byte for byte, and data that isn't JSON is
/// returned as it was, so the decoder reports the real problem.
public enum LegacyLaneMigration {
    public static func migrate(_ data: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        var changed = false
        let migrated = rewrite(root, changed: &changed)
        guard changed, let out = try? JSONSerialization.data(withJSONObject: migrated, options: [.prettyPrinted, .sortedKeys]) else {
            return data
        }
        return out
    }

    private static func rewrite(_ value: Any, changed: inout Bool) -> Any {
        if let array = value as? [Any] {
            return array.map { rewrite($0, changed: &changed) }
        }
        guard var object = value as? [String: Any] else { return value }

        // A lane predicate's payload: {"lane": {"_0": ["ciRunning", ...]}}.
        if let lane = object["lane"] as? [String: Any], let names = lane["_0"] as? [String] {
            let mapped = names.compactMap { Lane.migrating($0)?.rawValue }
            var seen = Set<String>()
            let unique = mapped.filter { seen.insert($0).inserted }
            if unique != names {
                changed = true
                object["lane"] = ["_0": unique]
            }
            return object
        }

        // A group: {"match": ..., "conditions": [...]}. Drop conditions left without lanes.
        if let conditions = object["conditions"] as? [Any] {
            let rewritten = conditions.map { rewrite($0, changed: &changed) }
            let kept = rewritten.filter { !isEmptyLaneCondition($0) }
            if kept.count != rewritten.count {
                changed = true
                if kept.isEmpty { object["match"] = "all" }
            }
            object["conditions"] = kept
            for (key, inner) in object where key != "conditions" {
                object[key] = rewrite(inner, changed: &changed)
            }
            return object
        }

        for (key, inner) in object {
            object[key] = rewrite(inner, changed: &changed)
        }
        return object
    }

    /// `{"predicate": {"_0": P}}` where P is a lane predicate with no lanes, or `not` of one.
    private static func isEmptyLaneCondition(_ value: Any) -> Bool {
        guard let condition = value as? [String: Any],
              let wrapper = condition["predicate"] as? [String: Any],
              let predicate = wrapper["_0"]
        else { return false }
        return isEmptyLanePredicate(predicate)
    }

    private static func isEmptyLanePredicate(_ value: Any) -> Bool {
        guard let predicate = value as? [String: Any] else { return false }
        if let lane = predicate["lane"] as? [String: Any], let names = lane["_0"] as? [Any] {
            return names.isEmpty
        }
        if let not = predicate["not"] as? [String: Any], let inner = not["_0"] {
            return isEmptyLanePredicate(inner)
        }
        return false
    }
}
