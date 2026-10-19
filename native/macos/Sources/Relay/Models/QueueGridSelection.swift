import Foundation

struct QueueGridSnapshot: Equatable {
    let ids: [String]
    let selected: Set<String>
}

/// The grid has one keyboard focus stop. Its cursor always belongs to the
/// selection, so preview and removal can both act on the visible selection.
struct QueueGridSelection {
    private(set) var cursor: String?
    private(set) var anchor: String?

    mutating func select(_ id: String, in ids: [String], selected: Set<String>, extending: Bool = false, toggling: Bool = false) -> Set<String> {
        guard ids.contains(id) else { return selected.intersection(ids) }
        let current = selected.intersection(ids)
        if extending {
            let start = anchor.flatMap { ids.contains($0) ? $0 : nil }
                ?? cursor.flatMap { current.contains($0) ? $0 : nil }
                ?? ids.first(where: current.contains) ?? id
            anchor = start; cursor = id
            let first = ids.firstIndex(of: start)!, last = ids.firstIndex(of: id)!
            let range = Set(ids[min(first, last)...max(first, last)])
            return toggling ? current.union(range) : range
        }
        if toggling {
            var next = current
            if !next.insert(id).inserted { next.remove(id) }
            cursor = next.contains(id) ? id : ids.first(where: next.contains)
            anchor = cursor
            return next
        }
        cursor = id; anchor = id
        return [id]
    }

    mutating func move(by offset: Int, in ids: [String], selected: Set<String>, extending: Bool) -> Set<String> {
        guard let first = ids.first else { cursor = nil; anchor = nil; return [] }
        let current = selected.intersection(ids)
        let start = cursor.flatMap { current.contains($0) ? $0 : nil } ?? ids.first(where: current.contains)
        guard let start, let index = ids.firstIndex(of: start) else {
            return select(first, in: ids, selected: current)
        }
        let destination = ids[max(0, min(ids.count - 1, index + offset))]
        if extending, anchor == nil { anchor = start }
        return select(destination, in: ids, selected: current, extending: extending)
    }

    mutating func selectAll(in ids: [String], selected: Set<String>) -> Set<String> {
        reconcile(in: ids, selected: selected)
        cursor = cursor ?? ids.first; anchor = anchor ?? cursor
        return Set(ids)
    }

    /// Reconciles list/grid switches, external selection changes and filtering.
    mutating func reconcile(in ids: [String], selected: Set<String>) {
        let current = selected.intersection(ids)
        guard !current.isEmpty else { cursor = nil; anchor = nil; return }
        if cursor.map({ !current.contains($0) }) ?? true {
            cursor = ids.first(where: current.contains); anchor = cursor
        }
        if anchor.map({ !ids.contains($0) }) ?? true { anchor = cursor }
    }

    /// After removing the focused selection, keep the same position if possible.
    static func replacement(for cursor: String?, oldIDs: [String], newIDs: [String]) -> String? {
        guard let cursor, !newIDs.contains(cursor), let index = oldIDs.firstIndex(of: cursor), !newIDs.isEmpty else { return nil }
        return newIDs[min(index, newIDs.count - 1)]
    }
}
