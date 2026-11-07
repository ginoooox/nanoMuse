import Foundation
import SQLite3

func check(_ value: Bool, _ label: String) {
    if !value { fatalError(label) }
}
check(NanoMuseSyncOrdering.relaySequence(NSNumber(value: 9)) == 9, "integer seq")
check(NanoMuseSyncOrdering.relaySequence(NSNumber(value: true)) == nil, "bool is not seq")
check(NanoMuseSyncOrdering.relaySequence(NSNumber(value: 1.5)) == nil, "fraction is not seq")
check(NanoMuseSyncOrdering.relaySequence(NSNumber(value: -1)) == nil, "negative is not seq")
check(NanoMuseSyncOrdering.relaySequence("9") == nil, "text is not seq")
let path = CommandLine.arguments[1]
var db: OpaquePointer?
check(sqlite3_open(path, &db) == SQLITE_OK, "open")
let schema = """
CREATE TABLE sessions(id TEXT PRIMARY KEY);
INSERT INTO sessions VALUES('s');
CREATE TABLE messages(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,role TEXT NOT NULL,parts_json TEXT NOT NULL,created_at REAL NOT NULL,sort_order INTEGER NOT NULL,updated_at REAL,part_flags INTEGER NOT NULL DEFAULT 0);
CREATE TABLE compact_markers(id TEXT PRIMARY KEY,session_id TEXT,first_kept_message_id TEXT,last_compacted_message_id TEXT,first_kept_sort_order INTEGER,boundary_message_id TEXT,ui_boundary_sort_order INTEGER);
"""
check(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "schema")
func put(_ id: String, _ seq: Int64?, _ second: Double = 100, parent: String? = nil) throws {
    try NanoMuseSyncOrdering.write(db, domain: "relay/account", cid: "c", session: "s", mid: id, seq: seq, parent: parent,
        message: .init(role: id.hasPrefix("z") ? "user" : "assistant", parts: "[]", created: second), reorder: true)
}
func loaded() -> [String] {
    var stmt: OpaquePointer?
    check(sqlite3_prepare_v2(db, "SELECT id FROM messages WHERE session_id='s' ORDER BY sort_order,created_at,id", -1, &stmt, nil) == SQLITE_OK, "load prepare")
    defer { sqlite3_finalize(stmt) }
    var ids: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW { ids.append(String(cString: sqlite3_column_text(stmt,0))) }
    return ids
}
// IDs intentionally sort answers first. Real relay seq must win inside the second.
try put("a2", 4); try put("z2", 3); try put("a1", 2); try put("z1", 1)
check(try NanoMuseSyncOrdering.orderedIDs(db, session: "s") == ["z1","a1","z2","a2"], "reverse arrival")
check(loaded() == ["z1","a1","z2","a2"], "physical sort_order")
check(sqlite3_exec(db, "INSERT INTO compact_markers VALUES('marker','s',NULL,NULL,1,NULL,NULL)", nil, nil, nil) == SQLITE_OK, "legacy marker")
try put("a1", 2)
check(try NanoMuseSyncOrdering.orderedIDs(db, session: "s").count == 4, "replay")
do { try put("a1", 90); fatalError("conflict accepted") } catch NanoMuseSyncOrdering.Failure.conflict {}
// Unknown seq fallback is deterministic; backfill must reorder already-present rows.
try put("a3", nil, 110); try put("z3", nil, 110)
try put("z3", 5, 110); try put("a3", 6, 110)
check(try NanoMuseSyncOrdering.orderedIDs(db, session: "s").suffix(2) == ["z3","a3"], "metadata backfill")
// Receipt before pull: genuine parent edge handles local fractional Q in same second.
check(sqlite3_exec(db, "INSERT INTO messages VALUES('local','s','user','[]',120.9,6,120.9,0)", nil, nil, nil) == SQLITE_OK, "local insert")
try put("reply", nil, 120, parent: "local")
check(try NanoMuseSyncOrdering.orderedIDs(db, session: "s").suffix(2) == ["local","reply"], "receipt parent")
// Failure in rank writes must roll back both the new row and its metadata.
check(sqlite3_exec(db, "CREATE TRIGGER fail_rank BEFORE UPDATE OF sort_order ON messages BEGIN SELECT RAISE(ABORT,'injected'); END", nil, nil, nil) == SQLITE_OK, "fault trigger")
do { try put("failure", 100, 130); fatalError("failure accepted") } catch {}
check(sqlite3_exec(db, "DROP TRIGGER fail_rank", nil, nil, nil) == SQLITE_OK, "drop trigger")
check(!(try NanoMuseSyncOrdering.orderedIDs(db, session: "s")).contains("failure"), "transaction rollback")
// Cross-account evidence cannot hijack a row in an already-owned local session.
do {
    try NanoMuseSyncOrdering.write(db, domain: "other/account", cid: "c", session: "s", mid: "z1", seq: 1, reorder: true)
    fatalError("cross-domain accepted")
} catch {}
// Inconsistent causal evidence rolls back instead of arbitrarily breaking an edge.
try put("cycle-a", nil, 125, parent: "cycle-b")
do { try put("cycle-b", nil, 125, parent: "cycle-a"); fatalError("cycle accepted") } catch NanoMuseSyncOrdering.Failure.cycle {}
check(!loaded().contains("cycle-b"), "cycle rollback")
let before = try NanoMuseSyncOrdering.orderedIDs(db, session: "s")
try NanoMuseSyncOrdering.repair(db, session: "s")
try NanoMuseSyncOrdering.repair(db, session: "s")
check(try NanoMuseSyncOrdering.orderedIDs(db, session: "s") == before, "repair idempotent")
check(sqlite3_close(db) == SQLITE_OK, "close")
check(sqlite3_open(path, &db) == SQLITE_OK, "cold open")
check(try NanoMuseSyncOrdering.orderedIDs(db, session: "s") == before, "cold durable ordering")
check(loaded() == before, "cold physical sort_order")
var marker: OpaquePointer?
check(sqlite3_prepare_v2(db, "SELECT first_kept_message_id FROM compact_markers WHERE id='marker'", -1, &marker, nil) == SQLITE_OK, "marker prepare")
check(sqlite3_step(marker) == SQLITE_ROW, "marker row")
check(String(cString: sqlite3_column_text(marker,0)) == "a1", "marker identity retained")
sqlite3_finalize(marker)
// Removing local account data must release the old local-session binding.
check(sqlite3_exec(db, "INSERT INTO sessions VALUES('gone')", nil, nil, nil) == SQLITE_OK, "delete fixture")
try NanoMuseSyncOrdering.write(db, domain: "lifecycle/account", cid: "life", session: "gone", mid: "life-mid", seq: 10, reorder: false)
check(sqlite3_exec(db, "DELETE FROM sessions WHERE id='gone'; INSERT INTO sessions VALUES('again')", nil, nil, nil) == SQLITE_OK, "delete account session")
try NanoMuseSyncOrdering.write(db, domain: "lifecycle/account", cid: "life", session: "again", mid: "life-mid", seq: 10, reorder: false)
// Confirmed relay wipe permits a new acceptance seq; ordinary replay above still rejects it.
try NanoMuseSyncOrdering.reset(db, domain: "lifecycle/account")
try NanoMuseSyncOrdering.write(db, domain: "lifecycle/account", cid: "life", session: "again", mid: "life-mid", seq: 99, reorder: false)
// Active-at-write-boundary: metadata is durable, body/rank are explicitly deferred.
let ranksBefore = loaded()
let deferred = try NanoMuseSyncOrdering.write(db, domain: "relay/account", cid: "c", session: "s", mid: "active-body", seq: 20,
    message: .init(role: "user", parts: "[]", created: 200), reorder: true, active: true)
check(deferred == .deferred && loaded() == ranksBefore, "active body must not report written")
check(try !NanoMuseSyncOrdering.repair(db, session: "s", active: true), "active repair deferred")
try put("active-body", 20, 200)
check(loaded().last == "active-body", "idle body replay")
// Metadata-only updates wait without requiring a pending body.
check(sqlite3_exec(db, "INSERT INTO messages VALUES('meta-z','s','user','[]',210,100,210,0); INSERT INTO messages VALUES('meta-a','s','assistant','[]',210,101,210,0)", nil, nil, nil) == SQLITE_OK, "metadata-only fixture")
try NanoMuseSyncOrdering.write(db, domain: "relay/account", cid: "c", session: "s", mid: "meta-a", seq: 22, reorder: false, active: true)
try NanoMuseSyncOrdering.write(db, domain: "relay/account", cid: "c", session: "s", mid: "meta-z", seq: 21, reorder: false, active: true)
try NanoMuseSyncOrdering.repair(db, session: "s")
check(loaded().suffix(2) == ["meta-z","meta-a"], "metadata-only idle repair")
check(try !NanoMuseSyncOrdering.needsRepair(db, session: "s"), "healthy order skips rewrite")
check(sqlite3_exec(db, "UPDATE messages SET sort_order=500 WHERE id='z1'", nil, nil, nil) == SQLITE_OK, "damaged rank")
check(try NanoMuseSyncOrdering.needsRepair(db, session: "s"), "damaged order detected")
try NanoMuseSyncOrdering.repair(db, session: "s")
check(try !NanoMuseSyncOrdering.needsRepair(db, session: "s"), "repair becomes no-op")
check(NanoMuseSyncOrdering.needsBackfill(cursor: 42, version: nil), "old nonzero cursor migrates")
check(!NanoMuseSyncOrdering.needsBackfill(cursor: 42, version: 1), "migration completes once")
check(!NanoMuseSyncOrdering.needsBackfill(cursor: 0, version: nil), "new install normal pull")
let generation = UUID()
let accountScope = NanoMuseSyncOrdering.Scope(account: "a", domain: "relay/a", generation: generation)
check(accountScope != .init(account: "b", domain: "relay/b", generation: generation), "account fence")
check(accountScope != .init(account: "a", domain: "other/a", generation: generation), "relay fence")
check(accountScope != .init(account: "a", domain: "relay/a", generation: UUID()), "ABA generation fence")
check(sqlite3_close(db) == SQLITE_OK, "cold close")
print("Swift SQLite production helper: reverse/replay/backfill/receipt/conflict/rollback/repair/cold/delete/reset/active/metadata/scope PASS")
