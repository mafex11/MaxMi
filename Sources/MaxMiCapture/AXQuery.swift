import Foundation

/// Path expressions over an `AXNode` tree, so a parser declares *where* its content lives
/// instead of re-deriving it from geometry per app.
///
/// The API is total: it never throws. A malformed path is a programmer error, so it traps in
/// debug builds and degrades to nil / [] in release. Parsed paths are cached, because the
/// anchored parsers evaluate the same handful of literals on every capture tick.
public enum AXQuery {
    // MARK: - Grammar

    enum Axis: Equatable {
        /// `/Role` — a direct child.
        case child
        /// `//Role` — any descendant.
        case descendant
    }

    enum Operator: String, Equatable {
        case equals = "="
        case prefix = "^="
        case contains = "*="
    }

    /// `description` is an alias of `label`: `AXReader` folds kAXDescriptionAttribute into
    /// `label`, so the two names resolve to the same field (spec §12 Q1).
    enum Attribute: String, Equatable, CaseIterable {
        case role, subrole, title, description, label, value, identifier, domId, domClass
    }

    struct Predicate: Equatable {
        let attribute: Attribute
        let op: Operator
        let expected: String
    }

    struct Step: Equatable {
        let axis: Axis
        /// nil == the `*` wildcard.
        let role: String?
        /// ANDed.
        let predicates: [Predicate]
        /// Zero-based, applied to the matches this step produced.
        let index: Int?
    }

    // MARK: - Invalid-path policy

    /// A malformed path is a programmer error, not input, so debug builds trap on it and release
    /// builds degrade to nil / []. Declared in BOTH configurations — the grammar's own tests flip
    /// it off to assert the release behaviour, and `swift test -c release` has to compile them.
    #if DEBUG
    nonisolated(unsafe) static var trapsOnInvalidPath = true
    #else
    nonisolated(unsafe) static var trapsOnInvalidPath = false
    #endif

    static func invalid(_ path: String, _ reason: String) -> [Step]? {
        if trapsOnInvalidPath {
            preconditionFailure("AXQuery: malformed path \"\(path)\" — \(reason)")
        }
        return nil
    }

    // MARK: - Parsing

    static func parsePath(_ path: String) -> [Step]? {
        guard !path.isEmpty else { return invalid(path, "empty path") }
        guard path.hasPrefix("/") else { return invalid(path, "a path must start with / or //") }
        var chars = Array(path)
        var i = 0
        var steps: [Step] = []
        while i < chars.count {
            guard chars[i] == "/" else { return invalid(path, "expected / at offset \(i)") }
            i += 1
            var axis = Axis.child
            if i < chars.count, chars[i] == "/" {
                axis = .descendant
                i += 1
            }
            // Role token: `*` or an identifier of letters, digits and underscores.
            var role: String? = nil
            if i < chars.count, chars[i] == "*" {
                i += 1
            } else {
                var token = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    token.append(chars[i])
                    i += 1
                }
                guard !token.isEmpty else { return invalid(path, "empty role token at offset \(i)") }
                role = token
            }
            // Bracket groups: `[n]` or `[attr op "value"]`, any number, all ANDed.
            var predicates: [Predicate] = []
            var index: Int? = nil
            while i < chars.count, chars[i] == "[" {
                i += 1
                guard let close = chars[i...].firstIndex(of: "]") else {
                    return invalid(path, "unterminated [")
                }
                let body = String(chars[i..<close])
                i = close + 1
                if body.allSatisfy(\.isNumber), !body.isEmpty {
                    guard index == nil, let n = Int(body) else {
                        return invalid(path, "at most one index per step")
                    }
                    index = n
                } else if let predicate = parsePredicate(body) {
                    predicates.append(predicate)
                } else {
                    return invalid(path, "bad predicate [\(body)]")
                }
            }
            steps.append(Step(axis: axis, role: role, predicates: predicates, index: index))
            // Anything that is not the start of the next step is junk.
            if i < chars.count, chars[i] != "/" { return invalid(path, "trailing junk at offset \(i)") }
        }
        guard !steps.isEmpty else { return invalid(path, "no steps") }
        return steps
    }

    static func parsePredicate(_ body: String) -> Predicate? {
        // Longest operator first so `^=` and `*=` are not read as an attribute ending in ^ or *.
        for op in [Operator.prefix, .contains, .equals] {
            guard let split = body.range(of: op.rawValue) else { continue }
            let name = String(body[..<split.lowerBound])
            let rest = String(body[split.upperBound...])
            guard let attribute = Attribute(rawValue: name) else { return nil }
            guard rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") else { return nil }
            return Predicate(attribute: attribute, op: op,
                             expected: String(rest.dropFirst().dropLast()))
        }
        return nil
    }

    // MARK: - Path cache

    static let pathCacheCapacity = 128

    /// Lock-guarded LRU. Only successful parses are cached; a malformed path is a programmer
    /// error that will be fixed, not a hot path worth remembering.
    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [Step]] = [:]
        /// Least-recently-used first.
        private var order: [String] = []

        func steps(for path: String, parse: (String) -> [Step]?) -> [Step]? {
            lock.lock()
            if let hit = entries[path] {
                order.removeAll { $0 == path }
                order.append(path)
                lock.unlock()
                return hit
            }
            lock.unlock()
            guard let parsed = parse(path) else { return nil }
            lock.lock()
            entries[path] = parsed
            order.removeAll { $0 == path }
            order.append(path)
            while order.count > AXQuery.pathCacheCapacity {
                entries.removeValue(forKey: order.removeFirst())
            }
            lock.unlock()
            return parsed
        }

        func count() -> Int {
            lock.lock(); defer { lock.unlock() }
            return entries.count
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
            order.removeAll()
        }
    }

    private static let pathCache = PathCache()

    static func steps(for path: String) -> [Step]? {
        pathCache.steps(for: path, parse: parsePath)
    }

    static func cachedPathCount() -> Int { pathCache.count() }

    static func resetPathCache() { pathCache.removeAll() }
}
