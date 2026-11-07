import Foundation
import CoreFoundation
import SQLite3

/// Local-only ordering evidence. seq is relay acceptance order, never a timestamp.
/// Shared by ChatStore and the standalone macOS SQLite regression executable.
enum NanoMuseSyncOrdering {
    enum Failure: Error { case sqlite(Int32), conflict, cycle, missingMessage }
    struct Message { let role: String; let parts: String; let created: Double }
    private struct Row {
        let id: String; let created: Double; let ordinal: Int64
        let seq: Int64?; let parent: String?; let domain: String?; let cid: String?
    }
    static let migrateSQL = """
    CREATE TABLE IF NOT EXISTS nm_sync_order (
      domain TEXT NOT NULL, cid TEXT NOT NULL, session_id TEXT NOT NULL,
      mid TEXT NOT NULL, seq INTEGER, parent_mid TEXT,
      PRIMARY KEY(domain,cid,mid), UNIQUE(session_id,mid)
    )
    """
    static let upsertSQL = """
    INSERT INTO nm_sync_order(domain,cid,session_id,mid,seq,parent_mid) VALUES(?,?,?,?,?,?)
    ON CONFLICT(domain,cid,mid) DO UPDATE SET
      seq=COALESCE(nm_sync_order.seq,excluded.seq),
      parent_mid=COALESCE(nm_sync_order.parent_mid,excluded.parent_mid)
    WHERE nm_sync_order.session_id=excluded.session_id
    """
    static let insertSQL = """
    INSERT OR IGNORE INTO messages(id,session_id,role,parts_json,created_at,updated_at,part_flags,sort_order)
    SELECT ?,?,?,?,?,?,?,COALESCE((SELECT MAX(sort_order)+1 FROM messages WHERE session_id=?),0)
    WHERE EXISTS(SELECT 1 FROM sessions WHERE id=?)
    """
    static let rowsSQL = """
    SELECT m.id,m.created_at,m.sort_order,o.mid,o.seq,o.parent_mid,o.domain,o.cid
    FROM messages m LEFT JOIN nm_sync_order o
      ON o.session_id=m.session_id AND o.mid=LOWER(m.id)
    WHERE m.session_id=? ORDER BY m.created_at,m.id
    """
    static let rankSQL = """
    UPDATE messages SET sort_order=? WHERE session_id=? AND id=?
    """
    /// JSONSerialization produces NSNumber, including Bool. Accept positive integer seq only.
    static func relaySequence(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue), integer > 0 else { return nil }
        return integer
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func statement(_ db: OpaquePointer?, _ sql: String, _ values: [Any?] = [],
                                  row: ((OpaquePointer) throws -> Void)? = nil) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &pointer, nil)
        guard code == SQLITE_OK, let stmt = pointer else { throw Failure.sqlite(code) }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case let text as String: result = sqlite3_bind_text(stmt, index, text, -1, transient)
            case let integer as Int64: result = sqlite3_bind_int64(stmt, index, integer)
            case let number as Double: result = sqlite3_bind_double(stmt, index, number)
            case nil: result = sqlite3_bind_null(stmt, index)
            default: throw Failure.conflict
            }
            guard result == SQLITE_OK else { throw Failure.sqlite(result) }
        }
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            try row?(stmt)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw Failure.sqlite(step) }
    }
    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
    static func migrate(_ db: OpaquePointer?) throws { try statement(db, migrateSQL) }

    /// SAVEPOINT composes with an existing ChatStore transaction; all failures propagate.
    private static func atomic(_ db: OpaquePointer?, _ body: () throws -> Void) throws {
        try statement(db, "SAVEPOINT nm_sync_order_write")
        do {
            try body()
            try statement(db, "RELEASE nm_sync_order_write")
        } catch {
            try? statement(db, "ROLLBACK TO nm_sync_order_write")
            try? statement(db, "RELEASE nm_sync_order_write")
            throw error
        }
    }
    static func write(_ db: OpaquePointer?, domain: String, cid: String, session: String,
                      mid: String, seq: Int64?, parent: String? = nil,
                      message: Message? = nil, reorder: Bool) throws {
        guard !domain.isEmpty, !cid.isEmpty, !mid.isEmpty, seq == nil || seq! > 0 else { throw Failure.conflict }
        let key = mid.lowercased()
        try atomic(db) {
            try migrate(db)
            try statement(db, "SELECT session_id,seq,parent_mid FROM nm_sync_order WHERE domain=? AND cid=? AND mid=?", [domain,cid,key]) { stmt in
                guard text(stmt,0) == session else { throw Failure.conflict }
                if let seq, sqlite3_column_type(stmt,1) != SQLITE_NULL, sqlite3_column_int64(stmt,1) != seq { throw Failure.conflict }
                if let parent, let old = text(stmt,2), old != parent.lowercased() { throw Failure.conflict }
            }
            try statement(db, upsertSQL, [domain,cid,session,key,seq,parent?.lowercased()])
            if let message {
                var exists = false
                try statement(db, "SELECT session_id FROM messages WHERE LOWER(id)=?", [key]) { stmt in
                    guard text(stmt,0) == session else { throw Failure.conflict }
                    exists = true
                }
                if !exists {
                    try statement(db, insertSQL, [key,session,message.role,message.parts,message.created,message.created,Int64(1),session,session])
                    guard sqlite3_changes(db) == 1 else { throw Failure.missingMessage }
                }
            }
            if reorder { try rewrite(db, session: session) }
        }
    }
    private static func rows(_ db: OpaquePointer?, session: String) throws -> [Row] {
        try migrate(db)
        var result: [Row] = []
        try statement(db, rowsSQL, [session]) { stmt in
            guard let id = text(stmt,0) else { throw Failure.conflict }
            result.append(Row(id:id, created:sqlite3_column_double(stmt,1), ordinal:sqlite3_column_int64(stmt,2),
                seq:sqlite3_column_type(stmt,4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt,4),
                parent:text(stmt,5), domain:text(stmt,6), cid:text(stmt,7)))
        }
        return result
    }
    static func hasEvidence(_ db: OpaquePointer?, session: String) throws -> Bool {
        try migrate(db)
        var found = false
        try statement(db, "SELECT 1 FROM nm_sync_order WHERE session_id=? LIMIT 1", [session]) { _ in found = true }
        return found
    }
    static func orderedIDs(_ db: OpaquePointer?, session: String) throws -> [String] {
        let all = try rows(db, session:session)
        guard all.allSatisfy({ $0.created.isFinite }) else { throw Failure.conflict }
        // Group by a true integer-second bucket, never synthesize subsecond times.
        let buckets = Dictionary(grouping:all, by:{ floor($0.created) })
        var result: [String] = []
        for second in buckets.keys.sorted() {
            let bucket = buckets[second]!.sorted {
                $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created
            }
            var edges = [String:Set<String>]()
            var incoming = Dictionary(uniqueKeysWithValues:bucket.map { ($0.id,0) })
            let byID = Dictionary(uniqueKeysWithValues:bucket.map { ($0.id.lowercased(),$0.id) })
            func edge(_ first: String, _ second: String) {
                guard first != second else { return }
                if edges[first,default:[]].insert(second).inserted { incoming[second,default:0] += 1 }
            }
            // Only compare seq in its actual account/relay/cid domain.
            let sequenced = Dictionary(grouping:bucket.filter { $0.seq != nil }, by:{ [$0.domain ?? "", $0.cid ?? ""] })
            for group in sequenced.values {
                let sorted = group.sorted { $0.seq! < $1.seq! }
                for pair in zip(sorted,sorted.dropFirst()) {
                    guard pair.0.seq != pair.1.seq else { throw Failure.conflict }
                    edge(pair.0.id,pair.1.id)
                }
            }
            // Unmapped local messages retain their own relative order.
            let local = bucket.filter { $0.domain == nil }.sorted { $0.ordinal == $1.ordinal ? $0.id < $1.id : $0.ordinal < $1.ordinal }
            for pair in zip(local,local.dropFirst()) { edge(pair.0.id,pair.1.id) }
            for item in bucket {
                if let parent = item.parent, let actual = byID[parent] { edge(actual,item.id) }
            }
            var remaining = Set(bucket.map(\.id))
            while !remaining.isEmpty {
                guard let next = bucket.first(where:{ remaining.contains($0.id) && incoming[$0.id] == 0 }) else { throw Failure.cycle }
                result.append(next.id); remaining.remove(next.id)
                for id in edges[next.id] ?? [] { incoming[id,default:0] -= 1 }
            }
        }
        return result
    }
    private static func rewrite(_ db: OpaquePointer?, session: String) throws {
        let ids = try orderedIDs(db, session:session)
        // Preserve legacy marker identity before changing its numeric rank.
        try statement(db, """
        UPDATE compact_markers SET first_kept_message_id=(
          SELECT id FROM messages WHERE session_id=? AND sort_order=first_kept_sort_order ORDER BY id LIMIT 1)
        WHERE session_id=? AND first_kept_message_id IS NULL AND last_compacted_message_id IS NULL
        """, [session,session])
        for (index,id) in ids.enumerated() {
            try statement(db, rankSQL, [Int64(index),session,id])
        }
        try statement(db, """
        UPDATE compact_markers SET first_kept_sort_order=COALESCE(
          (SELECT sort_order FROM messages WHERE session_id=? AND id=first_kept_message_id),first_kept_sort_order),
          ui_boundary_sort_order=COALESCE(
          (SELECT sort_order FROM messages WHERE session_id=? AND id=boundary_message_id),ui_boundary_sort_order)
        WHERE session_id=?
        """, [session,session,session])
    }
    static func repair(_ db: OpaquePointer?, session: String) throws {
        try atomic(db) { try rewrite(db, session:session) }
    }
}
