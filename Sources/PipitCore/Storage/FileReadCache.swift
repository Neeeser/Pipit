import Foundation
import Synchronization

/// What was decoded from each of many files, kept for as long as the file it
/// came from is unchanged.
///
/// The archive on disk stays the source of truth. Every lookup compares the
/// file's `FileIdentity` with the one it had when it was read, so a hit costs a
/// `stat` and a stale entry is never returned. `AtomicFile` replaces a file
/// rather than writing into it, so a rewrite changes the identity even when the
/// size and the clock tick happen to match.
public final class FileReadCache<Value: Sendable>: Sendable {
    fileprivate struct Entry: Sendable {
        var identity: FileIdentity
        var value: Value
    }

    private let entries = Mutex<[String: Entry]>([:])
    /// Counts the entries stored, so a copy saved to disk can tell it is behind.
    private let stores = Atomic<Int>(0)

    public init() {}

    /// The cached value for the file at `path` if the file has not changed
    /// since, else what `load` reads, which is then kept.
    ///
    /// The identity is taken before `load` runs, so a write that lands during
    /// the read leaves an entry that no longer matches, and the next lookup
    /// reads the file again rather than keeping the older copy.
    public func value(at path: String, load: () throws -> Value) rethrows -> Value {
        guard let identity = FileIdentity(path: path) else { return try load() }
        if let hit = entries.withLock({ $0[path] }), hit.identity == identity {
            return hit.value
        }
        let value = try load()
        entries.withLock { $0[path] = Entry(identity: identity, value: value) }
        stores.add(1, ordering: .relaxed)
        return value
    }

    /// How many entries have been stored since the cache was made.
    public var changeCount: Int { stores.load(ordering: .relaxed) }

    /// Drops every entry.
    public func removeAll() {
        entries.withLock { $0.removeAll() }
    }
}

extension FileReadCache where Value: Codable {
    private struct Saved: Codable {
        struct Item: Codable {
            var identity: FileIdentity
            var value: Value
        }

        var format: Int
        var items: [String: Item]
    }

    /// The entries whose files are still as they were read, encoded.
    ///
    /// Checked again here, so a copy saved to disk never carries an entry for
    /// a file that has since changed or gone.
    public func encoded(format: Int) throws -> Data {
        let current = entries.withLock { $0 }.filter { FileIdentity(path: $0.key) == $0.value.identity }
        let saved = Saved(
            format: format,
            items: current.mapValues { Saved.Item(identity: $0.identity, value: $0.value) }
        )
        return try JSONEncoder().encode(saved)
    }

    /// Puts back what `encoded` wrote, unless it was written in another format.
    /// Entries already held win, because they were read in this process.
    @discardableResult
    public func restore(from data: Data, format: Int) -> Int {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.format == format
        else { return 0 }
        entries.withLock { held in
            for (path, item) in saved.items where held[path] == nil {
                held[path] = Entry(identity: item.identity, value: item.value)
            }
        }
        return saved.items.count
    }
}
