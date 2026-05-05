import AppKit
import CSQLite
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let searchLogger = Logger(subsystem: "io.github.aiclilog", category: "search")

enum LogSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

struct ProjectSummary: Identifiable, Hashable, Sendable {
    var id: String { cwd }
    let cwd: String
    let sessionCount: Int
    let updatedAt: Date
    let sources: [LogSource]

    var displayName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var sourceLabel: String {
        sources.map(\.displayName).joined(separator: " + ")
    }
}

struct CodexSession: Identifiable, Hashable, Sendable {
    var id: String { "\(source.rawValue):\(sessionID)" }
    let sessionID: String
    let source: LogSource
    let cwd: String
    let title: String
    let transcriptPath: String
    let updatedAt: Date
    let model: String
    let gitBranch: String

    var shortID: String {
        String(sessionID.prefix(8))
    }

    var displayTitle: String {
        title.isEmpty ? sessionID : title
    }
}

struct CleanMessage: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date?
    let speaker: String
    let message: String
}

struct QueryGroup: Identifiable, Hashable, Sendable {
    let id: String
    let query: CleanMessage
    let responses: [CleanMessage]

    var allMessages: [CleanMessage] {
        [query] + responses
    }

    var responseCount: Int {
        responses.count
    }
}

struct SearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let project: ProjectSummary
    let session: CodexSession
    let groupID: String
    let messageID: String
    let speaker: String
    let timestamp: Date?
    let snippet: String
}

enum CodexStoreError: LocalizedError {
    case databaseMissing(String)
    case databaseOpenFailed(String)
    case queryFailed(String)
    case rolloutMissing(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing(let path):
            return "Codex database not found: \(path)"
        case .databaseOpenFailed(let message):
            return "Could not open Codex database: \(message)"
        case .queryFailed(let message):
            return "Codex database query failed: \(message)"
        case .rolloutMissing(let path):
            return "Rollout file not found: \(path)"
        }
    }
}

final class CodexStore {
    private let codexHome: URL
    private var databasePath: String {
        codexHome.appendingPathComponent("state_5.sqlite").path
    }

    init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.codexHome = codexHome
    }

    func projects(limit: Int = 100) throws -> [ProjectSummary] {
        try withDatabase { db in
            try rows(
                db: db,
                sql: """
                select cwd, count(*) as sessions, max(updated_at) as updated_at
                from threads
                where archived = 0
                group by cwd
                order by max(updated_at_ms) desc, cwd asc
                limit ?
                """,
                bind: { sqlite3_bind_int($0, 1, Int32(limit)) }
            ) { stmt in
                ProjectSummary(
                    cwd: columnText(stmt, 0),
                    sessionCount: Int(sqlite3_column_int(stmt, 1)),
                    updatedAt: dateFromUnix(stmt, 2),
                    sources: [.codex]
                )
            }
        }
    }

    func sessions(cwd: String, limit: Int = 100) throws -> [CodexSession] {
        try withDatabase { db in
            try rows(
                db: db,
                sql: """
                select id, cwd, title, rollout_path, updated_at, coalesce(model, ''), coalesce(git_branch, '')
                from threads
                where archived = 0 and cwd = ?
                order by updated_at_ms desc, id desc
                limit ?
                """,
                bind: { stmt in
                    sqlite3_bind_text(stmt, 1, cwd, -1, sqliteTransientDestructor())
                    sqlite3_bind_int(stmt, 2, Int32(limit))
                }
            ) { stmt in
                CodexSession(
                    sessionID: columnText(stmt, 0),
                    source: .codex,
                    cwd: columnText(stmt, 1),
                    title: columnText(stmt, 2),
                    transcriptPath: columnText(stmt, 3),
                    updatedAt: dateFromUnix(stmt, 4),
                    model: columnText(stmt, 5),
                    gitBranch: columnText(stmt, 6)
                )
            }
        }
    }

    func allSessions() throws -> [CodexSession] {
        try withDatabase { db in
            try rows(
                db: db,
                sql: """
                select id, cwd, title, rollout_path, updated_at, coalesce(model, ''), coalesce(git_branch, '')
                from threads
                where archived = 0
                order by updated_at_ms desc, id desc
                """,
                bind: { _ in }
            ) { stmt in
                CodexSession(
                    sessionID: columnText(stmt, 0),
                    source: .codex,
                    cwd: columnText(stmt, 1),
                    title: columnText(stmt, 2),
                    transcriptPath: columnText(stmt, 3),
                    updatedAt: dateFromUnix(stmt, 4),
                    model: columnText(stmt, 5),
                    gitBranch: columnText(stmt, 6)
                )
            }
        }
    }

    func messages(for session: CodexSession) throws -> [CleanMessage] {
        let url = URL(fileURLWithPath: NSString(string: session.transcriptPath).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexStoreError.rolloutMissing(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return text.split(separator: "\n").enumerated().compactMap { lineNumber, line in
            guard
                let data = String(line).data(using: .utf8),
                let event = try? decoder.decode(RolloutEvent.self, from: data),
                event.type == "event_msg",
                let payload = event.payload
            else {
                return nil
            }

            let speaker: String
            switch payload.type {
            case "user_message":
                speaker = "You"
            case "agent_message":
                speaker = "Codex"
            default:
                return nil
            }

            guard let message = payload.message, !message.isEmpty else {
                return nil
            }

            return CleanMessage(
                id: "\(session.id):\(lineNumber)",
                timestamp: formatter.date(from: event.timestamp),
                speaker: speaker,
                message: message
            )
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw CodexStoreError.databaseMissing(databasePath)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            if db != nil { sqlite3_close(db) }
            throw CodexStoreError.databaseOpenFailed(message)
        }
        defer { sqlite3_close(db) }
        _ = try? execute(db: db, sql: "pragma busy_timeout = 5000", bind: { _ in }, map: { _ in () })
        _ = try? execute(db: db, sql: "pragma query_only = on", bind: { _ in }, map: { _ in () })
        return try body(db)
    }

    private func execute<T>(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void,
        map: (OpaquePointer?) -> T
    ) throws -> [T] {
        try rows(db: db, sql: sql, bind: bind, map: map)
    }

    private func rows<T>(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void,
        map: (OpaquePointer?) -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CodexStoreError.queryFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt)

        var results: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW {
                results.append(map(stmt))
            } else if status == SQLITE_DONE {
                return results
            } else {
                throw CodexStoreError.queryFailed(errorMessage(db))
            }
        }
    }
}

final class ClaudeStore {
    private let summaryReadLimit = 384 * 1024
    private let claudeHome: URL
    private var projectsPath: URL {
        claudeHome.appendingPathComponent("projects")
    }

    init(claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeHome = claudeHome
    }

    func projects() throws -> [ProjectSummary] {
        try projects(from: allSessions())
    }

    func projects(from sessions: [CodexSession]) throws -> [ProjectSummary] {
        var grouped: [String: (count: Int, updatedAt: Date)] = [:]
        for session in sessions {
            let existing = grouped[session.cwd]
            grouped[session.cwd] = (
                count: (existing?.count ?? 0) + 1,
                updatedAt: max(existing?.updatedAt ?? .distantPast, session.updatedAt)
            )
        }
        return grouped.map { cwd, value in
            ProjectSummary(cwd: cwd, sessionCount: value.count, updatedAt: value.updatedAt, sources: [.claude])
        }
        .sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.cwd < right.cwd
            }
            return left.updatedAt > right.updatedAt
        }
    }

    func sessions(cwd: String) throws -> [CodexSession] {
        try sessions(cwd: cwd, from: allSessions())
    }

    func sessions(cwd: String, from sessions: [CodexSession]) throws -> [CodexSession] {
        sessions
            .filter { $0.cwd == cwd }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.sessionID > right.sessionID
                }
                return left.updatedAt > right.updatedAt
            }
    }

    func allSessions() throws -> [CodexSession] {
        var sessions: [CodexSession] = []
        for file in try sessionFiles() {
            try Task.checkCancellation()
            if let session = sessionSummary(for: file) {
                sessions.append(session)
            }
        }
        return sessions
    }

    func messages(for session: CodexSession) throws -> [CleanMessage] {
        let url = URL(fileURLWithPath: session.transcriptPath)
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .enumerated()
            .compactMap { lineNumber, line in
                guard
                    let data = String(line).data(using: .utf8),
                    let event = try? decoder.decode(ClaudeEvent.self, from: data),
                    let speaker = speaker(for: event),
                    let message = cleanClaudeMessage(event.message?.content),
                    !message.isEmpty
                else {
                    return nil
                }
                return CleanMessage(
                    id: "\(session.id):\(lineNumber)",
                    timestamp: parseISO8601(event.timestamp),
                    speaker: speaker,
                    message: message
                )
            }
    }

    private func sessionFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: projectsPath.path) else {
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: projectsPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else {
                return nil
            }
            if url.pathComponents.contains("subagents") {
                return nil
            }
            return url
        }
    }

    private func sessionSummary(for url: URL) -> CodexSession? {
        guard let text = readSummaryPrefix(url), !text.isEmpty else {
            return nil
        }

        let decoder = JSONDecoder()
        var cwd: String?
        var sessionID = url.deletingPathExtension().lastPathComponent
        var title: String?
        var updatedAt = fileModificationDate(url)
        var gitBranch = ""

        for line in text.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let event = try? decoder.decode(ClaudeEvent.self, from: data)
            else {
                continue
            }
            cwd = cwd ?? event.cwd
            sessionID = event.sessionId ?? sessionID
            if gitBranch.isEmpty {
                gitBranch = event.gitBranch ?? ""
            }
            if let timestamp = event.timestamp.flatMap(parseISO8601) {
                updatedAt = max(updatedAt ?? .distantPast, timestamp)
            }
            if title == nil,
               event.type == "user",
               let message = cleanClaudeMessage(event.message?.content),
               !message.isEmpty {
                title = message.replacingOccurrences(of: "\n", with: " ")
            }
        }

        guard let cwd else {
            return nil
        }

        return CodexSession(
            sessionID: sessionID,
            source: .claude,
            cwd: cwd,
            title: String((title ?? sessionID).prefix(120)),
            transcriptPath: url.path,
            updatedAt: updatedAt ?? .distantPast,
            model: "Claude Code",
            gitBranch: gitBranch
        )
    }

    private func readSummaryPrefix(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }
        guard let data = try? handle.read(upToCount: summaryReadLimit), !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct SearchIndexSummary: Sendable {
    let indexedFiles: Int
    let indexedMessages: Int
}

private actor SearchIndexCoordinator {
    static let shared = SearchIndexCoordinator()

    func refresh(sessions: [CodexSession]) throws -> SearchIndexSummary {
        try SearchIndexStore().refresh(sessions: sessions)
    }
}

private final class SearchIndexStore {
    private struct FileSignature: Equatable {
        let size: Int64
        let modifiedAt: Double
    }

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AiCliLog", isDirectory: true)
    }

    private var previousSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(["AI", "CLI", "Log"].joined(separator: " "), isDirectory: true)
    }

    private var legacySupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(["Codex", "CLI", "Log"].joined(separator: " "), isDirectory: true)
    }

    private var databaseURL: URL {
        supportDirectory
            .appendingPathComponent("search-index.sqlite")
    }

    private var legacyDatabaseURL: URL {
        legacySupportDirectory.appendingPathComponent("search-index.sqlite")
    }

    private var previousDatabaseURL: URL {
        previousSupportDirectory.appendingPathComponent("search-index.sqlite")
    }

    func refresh(sessions: [CodexSession]) throws -> SearchIndexSummary {
        let db = try openDatabase()
        defer { sqlite3_close(db) }
        try ensureSchema(db)

        let activePaths = Set(sessions.map { normalizedTranscriptPath($0.transcriptPath) })
        try removeInactiveFiles(activePaths: activePaths, db: db)

        var indexedFiles = 0
        var indexedMessages = 0
        for session in sessions {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: NSString(string: session.transcriptPath).expandingTildeInPath)
            guard let signature = fileSignature(url), try indexedSignature(for: url.path, db: db) != signature else {
                continue
            }
            let messages = try messages(for: session)
            let groups = buildQueryGroups(from: messages)
            try replace(session: session, url: url, signature: signature, groups: groups, db: db)
            indexedFiles += 1
            indexedMessages += messages.count
        }

        return SearchIndexSummary(indexedFiles: indexedFiles, indexedMessages: indexedMessages)
    }

    func search(
        query: String,
        projects: [ProjectSummary],
        limit: Int
    ) throws -> (results: [SearchResult], limitHit: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([], false)
        }

        try migrateLegacyDatabaseIfNeeded()

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return ([], false)
        }

        let db = try openDatabase(createIfNeeded: false)
        defer { sqlite3_close(db) }

        let projectByPath = Dictionary(uniqueKeysWithValues: projects.map { ($0.cwd, $0) })
        let rows = try searchRows(query: trimmed, limit: limit + 1, db: db)
        let results = rows.map { row -> SearchResult in
            let source = LogSource(rawValue: row.source) ?? .codex
            let session = CodexSession(
                sessionID: row.sessionID,
                source: source,
                cwd: row.cwd,
                title: row.title,
                transcriptPath: row.transcriptPath,
                updatedAt: Date(timeIntervalSince1970: row.updatedAt),
                model: row.model,
                gitBranch: row.gitBranch
            )
            let project = projectByPath[row.cwd] ?? ProjectSummary(
                cwd: row.cwd,
                sessionCount: 1,
                updatedAt: session.updatedAt,
                sources: [source]
            )
            return SearchResult(
                id: row.stableID,
                project: project,
                session: session,
                groupID: row.groupID,
                messageID: row.messageID,
                speaker: row.speaker,
                timestamp: row.timestamp.map(Date.init(timeIntervalSince1970:)),
                snippet: row.snippet
            )
        }

        let limitHit = results.count > limit
        return (limitHit ? Array(results.prefix(limit)) : results, limitHit)
    }

    private struct SearchRow {
        let stableID: String
        let source: String
        let sessionID: String
        let cwd: String
        let title: String
        let transcriptPath: String
        let updatedAt: Double
        let model: String
        let gitBranch: String
        let groupID: String
        let messageID: String
        let speaker: String
        let timestamp: Double?
        let snippet: String
    }

    private func openDatabase(createIfNeeded: Bool = true) throws -> OpaquePointer? {
        try migrateLegacyDatabaseIfNeeded()
        if createIfNeeded {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        let flags = (createIfNeeded ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            if db != nil { sqlite3_close(db) }
            throw CodexStoreError.databaseOpenFailed(message)
        }
        try? execute(db, "pragma busy_timeout = 5000")
        if createIfNeeded {
            try? execute(db, "pragma journal_mode = WAL")
        } else {
            try? execute(db, "pragma query_only = on")
        }
        return db
    }

    private func migrateLegacyDatabaseIfNeeded() throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: databaseURL.path) else {
            return
        }
        guard let sourceURL = [previousDatabaseURL, legacyDatabaseURL].first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return
        }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: databaseURL)

        for suffix in ["-wal", "-shm"] {
            let legacySidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: legacySidecar.path), !fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.copyItem(at: legacySidecar, to: sidecar)
            }
        }
    }

    private func ensureSchema(_ db: OpaquePointer?) throws {
        try execute(db, """
        create table if not exists indexed_files (
            path text primary key,
            source text not null,
            size integer not null,
            modified_at real not null,
            indexed_at real not null
        );

        create table if not exists search_messages (
            rowid integer primary key,
            stable_id text not null unique,
            source text not null,
            session_id text not null,
            session_key text not null,
            cwd text not null,
            title text not null,
            transcript_path text not null,
            updated_at real not null,
            model text not null,
            git_branch text not null,
            group_id text not null,
            message_id text not null,
            speaker text not null,
            timestamp real,
            body text not null
        );

        create index if not exists search_messages_transcript_path_idx on search_messages(transcript_path);
        create index if not exists search_messages_date_idx on search_messages(timestamp, updated_at);

        create virtual table if not exists search_messages_fts
        using fts5(body, content='search_messages', content_rowid='rowid', tokenize='trigram');

        create trigger if not exists search_messages_ai after insert on search_messages begin
            insert into search_messages_fts(rowid, body) values (new.rowid, new.body);
        end;

        create trigger if not exists search_messages_ad after delete on search_messages begin
            insert into search_messages_fts(search_messages_fts, rowid, body)
            values('delete', old.rowid, old.body);
        end;

        create trigger if not exists search_messages_au after update on search_messages begin
            insert into search_messages_fts(search_messages_fts, rowid, body)
            values('delete', old.rowid, old.body);
            insert into search_messages_fts(rowid, body) values (new.rowid, new.body);
        end;
        """)
    }

    private func messages(for session: CodexSession) throws -> [CleanMessage] {
        switch session.source {
        case .codex:
            return try CodexStore().messages(for: session)
        case .claude:
            return try ClaudeStore().messages(for: session)
        }
    }

    private func replace(
        session: CodexSession,
        url: URL,
        signature: FileSignature,
        groups: [QueryGroup],
        db: OpaquePointer?
    ) throws {
        let indexedSession = CodexSession(
            sessionID: session.sessionID,
            source: session.source,
            cwd: session.cwd,
            title: session.title,
            transcriptPath: url.path,
            updatedAt: session.updatedAt,
            model: session.model,
            gitBranch: session.gitBranch
        )
        try execute(db, "begin immediate transaction")
        do {
            try execute(
                db,
                "delete from search_messages where transcript_path = ?",
                bind: { sqlite3_bind_text($0, 1, url.path, -1, sqliteTransientDestructor()) }
            )

            for group in groups {
                for message in group.allMessages {
                    try insert(message: message, group: group, session: indexedSession, db: db)
                }
            }

            try execute(
                db,
                """
                insert into indexed_files(path, source, size, modified_at, indexed_at)
                values (?, ?, ?, ?, ?)
                on conflict(path) do update set
                    source = excluded.source,
                    size = excluded.size,
                    modified_at = excluded.modified_at,
                    indexed_at = excluded.indexed_at
                """,
                bind: { stmt in
                    sqlite3_bind_text(stmt, 1, url.path, -1, sqliteTransientDestructor())
                    sqlite3_bind_text(stmt, 2, session.source.rawValue, -1, sqliteTransientDestructor())
                    sqlite3_bind_int64(stmt, 3, signature.size)
                    sqlite3_bind_double(stmt, 4, signature.modifiedAt)
                    sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
                }
            )

            try execute(db, "commit")
        } catch {
            try? execute(db, "rollback")
            throw error
        }
    }

    private func insert(message: CleanMessage, group: QueryGroup, session: CodexSession, db: OpaquePointer?) throws {
        try execute(
            db,
            """
            insert into search_messages(
                stable_id, source, session_id, session_key, cwd, title, transcript_path,
                updated_at, model, git_branch, group_id, message_id, speaker, timestamp, body
            ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, "\(session.id):\(group.id):\(message.id)", -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 2, session.source.rawValue, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 3, session.sessionID, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 4, session.id, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 5, session.cwd, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 6, session.title, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 7, session.transcriptPath, -1, sqliteTransientDestructor())
                sqlite3_bind_double(stmt, 8, session.updatedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 9, session.model, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 10, session.gitBranch, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 11, group.id, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 12, message.id, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 13, message.speaker, -1, sqliteTransientDestructor())
                if let timestamp = message.timestamp {
                    sqlite3_bind_double(stmt, 14, timestamp.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 14)
                }
                sqlite3_bind_text(stmt, 15, message.message, -1, sqliteTransientDestructor())
            }
        )
    }

    private func searchRows(query: String, limit: Int, db: OpaquePointer?) throws -> [SearchRow] {
        if query.count >= 3 {
            return try rows(
                db: db,
                sql: """
                select m.stable_id, m.source, m.session_id, m.cwd, m.title, m.transcript_path,
                       m.updated_at, m.model, m.git_branch, m.group_id, m.message_id, m.speaker,
                       m.timestamp,
                       snippet(search_messages_fts, 0, '', '', '...', 32)
                from search_messages_fts
                join search_messages m on search_messages_fts.rowid = m.rowid
                where search_messages_fts match ?
                order by coalesce(m.timestamp, m.updated_at) desc, m.stable_id desc
                limit ?
                """,
                bind: { stmt in
                    sqlite3_bind_text(stmt, 1, ftsLiteral(query), -1, sqliteTransientDestructor())
                    sqlite3_bind_int(stmt, 2, Int32(limit))
                },
                map: mapSearchRow
            )
        }

        return try rows(
            db: db,
            sql: """
            select stable_id, source, session_id, cwd, title, transcript_path,
                   updated_at, model, git_branch, group_id, message_id, speaker,
                   timestamp,
                   replace(substr(body, max(1, instr(lower(body), lower(?)) - 90), 220), char(10), ' ')
            from search_messages
            where body like ? escape '\\'
            order by coalesce(timestamp, updated_at) desc, stable_id desc
            limit ?
            """,
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, query, -1, sqliteTransientDestructor())
                sqlite3_bind_text(stmt, 2, likeLiteral(query), -1, sqliteTransientDestructor())
                sqlite3_bind_int(stmt, 3, Int32(limit))
            },
            map: mapSearchRow
        )
    }

    private func mapSearchRow(_ stmt: OpaquePointer?) -> SearchRow {
        SearchRow(
            stableID: columnText(stmt, 0),
            source: columnText(stmt, 1),
            sessionID: columnText(stmt, 2),
            cwd: columnText(stmt, 3),
            title: columnText(stmt, 4),
            transcriptPath: columnText(stmt, 5),
            updatedAt: sqlite3_column_double(stmt, 6),
            model: columnText(stmt, 7),
            gitBranch: columnText(stmt, 8),
            groupID: columnText(stmt, 9),
            messageID: columnText(stmt, 10),
            speaker: columnText(stmt, 11),
            timestamp: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 12),
            snippet: columnText(stmt, 13).replacingOccurrences(of: "\n", with: " ")
        )
    }

    private func removeInactiveFiles(activePaths: Set<String>, db: OpaquePointer?) throws {
        let paths = try rows(
            db: db,
            sql: "select path from indexed_files",
            bind: { _ in },
            map: { columnText($0, 0) }
        )
        for path in paths where !activePaths.contains(path) {
            try execute(
                db,
                "delete from search_messages where transcript_path = ?",
                bind: { sqlite3_bind_text($0, 1, path, -1, sqliteTransientDestructor()) }
            )
            try execute(
                db,
                "delete from indexed_files where path = ?",
                bind: { sqlite3_bind_text($0, 1, path, -1, sqliteTransientDestructor()) }
            )
        }
    }

    private func indexedSignature(for path: String, db: OpaquePointer?) throws -> FileSignature? {
        try rows(
            db: db,
            sql: "select size, modified_at from indexed_files where path = ?",
            bind: { sqlite3_bind_text($0, 1, path, -1, sqliteTransientDestructor()) },
            map: { FileSignature(size: sqlite3_column_int64($0, 0), modifiedAt: sqlite3_column_double($0, 1)) }
        ).first
    }

    private func fileSignature(_ url: URL) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return FileSignature(size: size.int64Value, modifiedAt: modifiedAt.timeIntervalSince1970)
    }

    private func execute(_ db: OpaquePointer?, _ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        if let bind {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw CodexStoreError.queryFailed(errorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw CodexStoreError.queryFailed(errorMessage(db))
            }
            return
        }

        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage(db)
            sqlite3_free(error)
            throw CodexStoreError.queryFailed(message)
        }
    }

    private func rows<T>(
        db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void,
        map: (OpaquePointer?) -> T
    ) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CodexStoreError.queryFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var values: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW {
                values.append(map(stmt))
            } else if status == SQLITE_DONE {
                return values
            } else {
                throw CodexStoreError.queryFailed(errorMessage(db))
            }
        }
    }
}

private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
    guard let raw = sqlite3_column_text(stmt, index) else {
        return ""
    }
    return String(cString: raw)
}

private func dateFromUnix(_ stmt: OpaquePointer?, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, index)))
}

private func errorMessage(_ db: OpaquePointer?) -> String {
    db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
}

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private struct RolloutEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: RolloutPayload?
}

private struct RolloutPayload: Decodable {
    let type: String
    let message: String?
}

private struct ClaudeEvent: Decodable {
    let type: String
    let cwd: String?
    let sessionId: String?
    let timestamp: String?
    let gitBranch: String?
    let message: ClaudeMessage?
}

private struct ClaudeMessage: Decodable {
    let role: String?
    let content: JSONValue?
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }
}

private func messageContains(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
}

private func ftsLiteral(_ query: String) -> String {
    "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func likeLiteral(_ query: String) -> String {
    let escaped = query
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    return "%\(escaped)%"
}

private func normalizedTranscriptPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

private func parseISO8601(_ raw: String?) -> Date? {
    guard let raw else {
        return nil
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) {
        return date
    }
    return ISO8601DateFormatter().date(from: raw)
}

private func fileModificationDate(_ url: URL) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
}

private func speaker(for event: ClaudeEvent) -> String? {
    switch event.type {
    case "user":
        return "You"
    case "assistant":
        return "Claude"
    default:
        return nil
    }
}

private func cleanClaudeMessage(_ content: JSONValue?) -> String? {
    guard let content else {
        return nil
    }
    switch content {
    case .string(let value):
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    case .array(let values):
        let text = values.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let type)? = object["type"],
                  type == "text",
                  case .string(let text)? = object["text"]
            else {
                return nil
            }
            return text
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    default:
        return nil
    }
}

private func snippet(from text: String, query: String, radius: Int = 90) -> String {
    guard let range = text.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
    ) else {
        return String(text.prefix(radius * 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
    var value = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    if start > text.startIndex {
        value = "..." + value
    }
    if end < text.endIndex {
        value += "..."
    }
    return value.replacingOccurrences(of: "\n", with: " ")
}

private func highlightedString(_ text: String, query: String) -> AttributedString {
    var attributed = AttributedString(text)
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return attributed
    }

    var searchStart = attributed.startIndex
    while searchStart < attributed.endIndex,
          let range = attributed[searchStart..<attributed.endIndex].range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
          ) {
        attributed[range].backgroundColor = .yellow.opacity(0.45)
        attributed[range].foregroundColor = .primary
        searchStart = range.upperBound
    }
    return attributed
}

private func buildQueryGroups(from messages: [CleanMessage]) -> [QueryGroup] {
    var groups: [QueryGroup] = []
    var currentQuery: CleanMessage?
    var currentResponses: [CleanMessage] = []

    func flush() {
        guard let query = currentQuery else {
            return
        }
        groups.append(QueryGroup(id: query.id, query: query, responses: currentResponses))
    }

    for message in messages {
        if message.speaker == "You" {
            flush()
            currentQuery = message
            currentResponses = []
        } else if currentQuery == nil {
            currentQuery = CleanMessage(
                id: "\(message.id):session",
                timestamp: message.timestamp,
                speaker: "Session",
                message: "Session messages"
            )
            currentResponses = [message]
        } else {
            currentResponses.append(message)
        }
    }
    flush()
    return groups
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectSummary] = []
    @Published var sessions: [CodexSession] = []
    @Published var messages: [CleanMessage] = []
    @Published var selectedProject: ProjectSummary?
    @Published var selectedSession: CodexSession?
    @Published var searchText = ""
    @Published var isSearchPresented = false
    @Published var searchResults: [SearchResult] = []
    @Published var selectedSearchProjectPath: String?
    @Published var selectedSearchSource: LogSource? {
        didSet {
            if oldValue != selectedSearchSource {
                selectedSearchProjectPath = nil
            }
        }
    }
    @Published var searchResultLimitHit = false
    @Published var isLoading = false
    @Published var isSearchLoading = false
    @Published var isSearchIndexing = false
    @Published var errorMessage: String?
    @Published var expandedQueryIDs: Set<String> = []
    @Published var activeSearchResultID: String?
    @Published var activeSearchGroupID: String?
    @Published var activeSearchMessageID: String?
    @Published var pendingSearchMessageID: String?

    private var knownClaudeSessions: [CodexSession] = []
    private var loadTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchIndexTask: Task<Void, Never>?
    private let searchResultLimit = 500

    private struct LoadSnapshot: Sendable {
        let projects: [ProjectSummary]
        let selectedProject: ProjectSummary?
        let sessions: [CodexSession]
        let selectedSession: CodexSession?
        let messages: [CleanMessage]
        let knownClaudeSessions: [CodexSession]
    }

    private struct SessionSnapshot: Sendable {
        let project: ProjectSummary
        let sessions: [CodexSession]
        let selectedSession: CodexSession?
        let messages: [CleanMessage]
    }

    private struct MessageSnapshot: Sendable {
        let session: CodexSession
        let messages: [CleanMessage]
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool {
        !trimmedSearchText.isEmpty
    }

    var searchProjectOptions: [ProjectSummary] {
        var seen: Set<String> = []
        var options: [ProjectSummary] = []
        for result in searchResults where !seen.contains(result.project.cwd) {
            if let selectedSearchSource, result.session.source != selectedSearchSource {
                continue
            }
            seen.insert(result.project.cwd)
            options.append(result.project)
        }
        return options
    }

    var filteredSearchResults: [SearchResult] {
        searchResults.filter { result in
            if let selectedSearchSource, result.session.source != selectedSearchSource {
                return false
            }
            if let selectedSearchProjectPath, result.project.cwd != selectedSearchProjectPath {
                return false
            }
            return true
        }
    }

    var searchSourceOptions: [LogSource] {
        LogSource.allCases.filter { source in
            searchResults.contains { result in
                if let selectedSearchProjectPath, result.project.cwd != selectedSearchProjectPath {
                    return false
                }
                return result.session.source == source
            }
        }
    }

    var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }

    func load() {
        loadTask?.cancel()
        sessionTask?.cancel()
        messageTask?.cancel()
        searchIndexTask?.cancel()
        isLoading = true
        let preferredProjectPath = selectedProject?.cwd
        let preferredSessionID = selectedSession?.id

        loadTask = Task { [weak self, preferredProjectPath, preferredSessionID] in
            do {
                let codexJob = Task.detached(priority: .userInitiated) {
                    try Self.loadSnapshot(
                        preferredProjectPath: preferredProjectPath,
                        preferredSessionID: preferredSessionID,
                        includeClaude: false
                    )
                }
                let codexSnapshot = try await withTaskCancellationHandler {
                    try await codexJob.value
                } onCancel: {
                    codexJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(codexSnapshot)
                self?.updateSearchResults()

                let currentProjectPath = self?.selectedProject?.cwd ?? preferredProjectPath
                let currentSessionID = self?.selectedSession?.id ?? preferredSessionID
                let fullJob = Task.detached(priority: .utility) {
                    try Self.loadSnapshot(
                        preferredProjectPath: currentProjectPath,
                        preferredSessionID: currentSessionID,
                        includeClaude: true
                    )
                }
                let fullSnapshot = try await withTaskCancellationHandler {
                    try await fullJob.value
                } onCancel: {
                    fullJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(fullSnapshot)
                self?.isLoading = false
                self?.refreshSearchIndexInBackground()
                self?.updateSearchResults()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    func loadSessions(for project: ProjectSummary) {
        sessionTask?.cancel()
        messageTask?.cancel()
        selectedProject = project
        selectedSession = nil
        sessions = []
        messages = []
        expandedQueryIDs = []
        clearActiveSearchTarget()
        isLoading = true
        let cachedClaudeSessions = knownClaudeSessions

        sessionTask = Task { [weak self, project] in
            do {
                let codexJob = Task.detached(priority: .userInitiated) {
                    try Self.sessionSnapshot(project: project, preferredSessionID: nil, includeClaude: false)
                }
                let codexSnapshot = try await withTaskCancellationHandler {
                    try await codexJob.value
                } onCancel: {
                    codexJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(codexSnapshot)

                let currentSessionID = self?.selectedSession?.id
                let fullJob = Task.detached(priority: .utility) {
                    try Self.sessionSnapshot(
                        project: project,
                        preferredSessionID: currentSessionID,
                        includeClaude: true,
                        knownClaudeSessions: cachedClaudeSessions
                    )
                }
                let fullSnapshot = try await withTaskCancellationHandler {
                    try await fullJob.value
                } onCancel: {
                    fullJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(fullSnapshot)
                self?.isLoading = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    func loadMessages(for session: CodexSession) {
        messageTask?.cancel()
        selectedSession = session
        messages = []
        expandedQueryIDs = []
        clearActiveSearchTarget()
        isLoading = true

        messageTask = Task { [weak self, session] in
            do {
                let messageJob = Task.detached(priority: .userInitiated) {
                    try Self.messageSnapshot(session: session)
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await messageJob.value
                } onCancel: {
                    messageJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(snapshot)
                self?.isLoading = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    var queryGroups: [QueryGroup] {
        buildQueryGroups(from: messages)
    }

    var visibleQueryGroups: [QueryGroup] {
        queryGroups
    }

    func updateSearchResults() {
        searchTask?.cancel()
        let query = trimmedSearchText
        guard !query.isEmpty else {
            searchResults = []
            selectedSearchProjectPath = nil
            selectedSearchSource = nil
            searchResultLimitHit = false
            isSearchLoading = false
            clearActiveSearchTarget()
            return
        }

        isSearchLoading = true
        let projects = projects
        let limit = searchResultLimit
        searchTask = Task { [weak self, query, projects, limit] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let searchJob = Task.detached(priority: .userInitiated) {
                    try Self.performGlobalSearch(
                        query: query,
                        projects: projects,
                        limit: limit
                    )
                }
                let response = try await withTaskCancellationHandler {
                    try await searchJob.value
                } onCancel: {
                    searchJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }

                self?.searchResults = response.results
                self?.searchResultLimitHit = response.limitHit
                if let selected = self?.selectedSearchProjectPath,
                   !response.results.contains(where: { $0.project.cwd == selected }) {
                    self?.selectedSearchProjectPath = nil
                }
                if let selected = self?.selectedSearchSource,
                   !response.results.contains(where: { $0.session.source == selected }) {
                    self?.selectedSearchSource = nil
                }
                self?.isSearchLoading = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.errorMessage = error.localizedDescription
                self?.isSearchLoading = false
            }
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        sessionTask?.cancel()
        messageTask?.cancel()
        let project = projects.first { $0.cwd == result.project.cwd } ?? result.project
        selectedProject = project
        selectedSession = result.session
        messages = []
        clearActiveSearchTarget()
        isLoading = true
        let cachedClaudeSessions = knownClaudeSessions

        sessionTask = Task { [weak self, project, result] in
            do {
                let sessionJob = Task.detached(priority: .userInitiated) {
                    try Self.sessionSnapshot(
                        project: project,
                        preferredSessionID: result.session.id,
                        includeClaude: true,
                        knownClaudeSessions: cachedClaudeSessions
                    )
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await sessionJob.value
                } onCancel: {
                    sessionJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(snapshot)
                self?.expandedQueryIDs.insert(result.groupID)
                self?.activeSearchResultID = result.id
                self?.activeSearchGroupID = result.groupID
                self?.activeSearchMessageID = result.messageID
                self?.pendingSearchMessageID = nil
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.pendingSearchMessageID = result.messageID
                }
                self?.isLoading = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    private func apply(_ snapshot: LoadSnapshot) {
        projects = snapshot.projects
        selectedProject = snapshot.selectedProject
        sessions = snapshot.sessions
        selectedSession = snapshot.selectedSession
        messages = snapshot.messages
        if !snapshot.knownClaudeSessions.isEmpty {
            knownClaudeSessions = snapshot.knownClaudeSessions
        }
        expandedQueryIDs = Set(queryGroups.map(\.id))
        clearActiveSearchTarget()
    }

    private func apply(_ snapshot: SessionSnapshot) {
        selectedProject = snapshot.project
        sessions = snapshot.sessions
        selectedSession = snapshot.selectedSession
        messages = snapshot.messages
        expandedQueryIDs = Set(queryGroups.map(\.id))
        clearActiveSearchTarget()
    }

    private func apply(_ snapshot: MessageSnapshot) {
        selectedSession = snapshot.session
        messages = snapshot.messages
        expandedQueryIDs = Set(queryGroups.map(\.id))
        clearActiveSearchTarget()
    }

    private nonisolated static func loadSnapshot(
        preferredProjectPath: String?,
        preferredSessionID: String?,
        includeClaude: Bool
    ) throws -> LoadSnapshot {
        try Task.checkCancellation()
        let store = CodexStore()
        var projectItems = try store.projects(limit: 500)
        var knownClaudeSessions: [CodexSession] = []
        if includeClaude {
            let claudeStore = ClaudeStore()
            knownClaudeSessions = try claudeStore.allSessions()
            projectItems += try claudeStore.projects(from: knownClaudeSessions)
        }
        let projects = mergedProjects(projectItems)
        try Task.checkCancellation()
        let selectedProject = projects.first { $0.cwd == preferredProjectPath } ?? projects.first
        guard let selectedProject else {
            return LoadSnapshot(
                projects: projects,
                selectedProject: nil,
                sessions: [],
                selectedSession: nil,
                messages: [],
                knownClaudeSessions: knownClaudeSessions
            )
        }

        let sessionSnapshot = try sessionSnapshot(
            project: selectedProject,
            preferredSessionID: preferredSessionID,
            includeClaude: includeClaude,
            knownClaudeSessions: knownClaudeSessions
        )
        return LoadSnapshot(
            projects: projects,
            selectedProject: selectedProject,
            sessions: sessionSnapshot.sessions,
            selectedSession: sessionSnapshot.selectedSession,
            messages: sessionSnapshot.messages,
            knownClaudeSessions: knownClaudeSessions
        )
    }

    private nonisolated static func sessionSnapshot(
        project: ProjectSummary,
        preferredSessionID: String?,
        includeClaude: Bool,
        knownClaudeSessions: [CodexSession] = []
    ) throws -> SessionSnapshot {
        try Task.checkCancellation()
        let sessions = try projectSessions(
            cwd: project.cwd,
            includeClaude: includeClaude,
            knownClaudeSessions: knownClaudeSessions
        )
        try Task.checkCancellation()
        let selectedSession = sessions.first { $0.id == preferredSessionID } ?? sessions.first
        let messages: [CleanMessage]
        if let selectedSession {
            messages = try sessionMessages(for: selectedSession)
        } else {
            messages = []
        }
        return SessionSnapshot(
            project: project,
            sessions: sessions,
            selectedSession: selectedSession,
            messages: messages
        )
    }

    private nonisolated static func messageSnapshot(session: CodexSession) throws -> MessageSnapshot {
        try Task.checkCancellation()
        return MessageSnapshot(session: session, messages: try sessionMessages(for: session))
    }

    private nonisolated static func projectSessions(
        cwd: String,
        includeClaude: Bool,
        knownClaudeSessions: [CodexSession] = []
    ) throws -> [CodexSession] {
        try Task.checkCancellation()
        let store = CodexStore()
        var sessions = try store.sessions(cwd: cwd)
        if includeClaude {
            let claudeStore = ClaudeStore()
            if knownClaudeSessions.isEmpty {
                sessions += try claudeStore.sessions(cwd: cwd)
            } else {
                sessions += try claudeStore.sessions(cwd: cwd, from: knownClaudeSessions)
            }
        }
        try Task.checkCancellation()
        return sessions
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.id > right.id
                }
                return left.updatedAt > right.updatedAt
            }
    }

    private nonisolated static func sessionMessages(for session: CodexSession) throws -> [CleanMessage] {
        try Task.checkCancellation()
        switch session.source {
        case .codex:
            return try CodexStore().messages(for: session)
        case .claude:
            return try ClaudeStore().messages(for: session)
        }
    }

    private nonisolated static func performGlobalSearch(
        query: String,
        projects: [ProjectSummary],
        limit: Int
    ) throws -> (results: [SearchResult], limitHit: Bool) {
        let startedAt = Date()
        let response = try SearchIndexStore().search(query: query, projects: projects, limit: limit)
        searchLogger.info("Search completed queryLength=\(query.count, privacy: .public) results=\(response.results.count, privacy: .public) limitHit=\(response.limitHit, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)")
        return response
    }

    private func refreshSearchIndexInBackground() {
        searchIndexTask?.cancel()
        isSearchIndexing = true
        let cachedClaudeSessions = knownClaudeSessions
        searchIndexTask = Task { [weak self, cachedClaudeSessions] in
            do {
                let refreshJob = Task.detached(priority: .utility) {
                    let startedAt = Date()
                    let sessions = try Self.allSearchSessions(knownClaudeSessions: cachedClaudeSessions)
                    let summary = try await SearchIndexCoordinator.shared.refresh(sessions: sessions)
                    searchLogger.info("Index refresh completed sessions=\(sessions.count, privacy: .public) files=\(summary.indexedFiles, privacy: .public) messages=\(summary.indexedMessages, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)")
                    return summary
                }
                _ = try await withTaskCancellationHandler {
                    try await refreshJob.value
                } onCancel: {
                    refreshJob.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.isSearchIndexing = false
                if self?.isSearching == true {
                    self?.updateSearchResults()
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.isSearchIndexing = false
            }
        }
    }

    private nonisolated static func allSearchSessions(knownClaudeSessions: [CodexSession]) throws -> [CodexSession] {
        try Task.checkCancellation()
        let codexSessions = try CodexStore().allSessions()
        let claudeSessions = knownClaudeSessions.isEmpty ? try ClaudeStore().allSessions() : knownClaudeSessions
        try Task.checkCancellation()
        return codexSessions + claudeSessions
    }

    private nonisolated static func mergedProjects(_ items: [ProjectSummary]) -> [ProjectSummary] {
        var grouped: [String: (count: Int, updatedAt: Date, sources: Set<LogSource>)] = [:]
        for item in items {
            var existing = grouped[item.cwd] ?? (count: 0, updatedAt: .distantPast, sources: [])
            existing.count += item.sessionCount
            existing.updatedAt = max(existing.updatedAt, item.updatedAt)
            existing.sources.formUnion(item.sources)
            grouped[item.cwd] = existing
        }
        return grouped.map { cwd, value in
            ProjectSummary(
                cwd: cwd,
                sessionCount: value.count,
                updatedAt: value.updatedAt,
                sources: LogSource.allCases.filter { value.sources.contains($0) }
            )
        }
        .sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.cwd < right.cwd
            }
            return left.updatedAt > right.updatedAt
        }
    }

    private func clearActiveSearchTarget() {
        activeSearchResultID = nil
        activeSearchGroupID = nil
        activeSearchMessageID = nil
        pendingSearchMessageID = nil
    }

    func expandAllQueries() {
        expandedQueryIDs = Set(queryGroups.map(\.id))
    }

    func collapseAllQueries() {
        expandedQueryIDs = []
    }

    func revealSelectedProjectInFinder() {
        guard let selectedProject else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedProject.cwd)])
    }

    func beginSearch() {
        isSearchPresented = true
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func restartApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
                return
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    func copyConversation() {
        let markdown = conversationMarkdown()
        guard !markdown.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func exportConversation() {
        guard let session = selectedSession else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = exportFileName(for: session)
        panel.title = "Export Conversation"
        panel.message = "Export the clean conversation as Markdown."
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try conversationMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func conversationMarkdown() -> String {
        guard let session = selectedSession else {
            return ""
        }

        var lines: [String] = [
            "# \(session.displayTitle)",
            "",
            "- source: \(session.source.displayName)",
            "- id: \(session.sessionID)",
            "- project: \(session.cwd)",
            "- updated: \(session.updatedAt.formatted(date: .numeric, time: .shortened))",
        ]
        if !session.model.isEmpty {
            lines.append("- model: \(session.model)")
        }
        if !session.gitBranch.isEmpty {
            lines.append("- branch: \(session.gitBranch)")
        }
        lines.append("")

        for message in messages {
            var heading = "## \(message.speaker)"
            if let timestamp = message.timestamp {
                heading += " - \(timestamp.formatted(date: .numeric, time: .shortened))"
            }
            lines.append(heading)
            lines.append("")
            lines.append(message.message)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func exportFileName(for session: CodexSession) -> String {
        let rawTitle = session.displayTitle
        let safeTitle = rawTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(session.source.rawValue)-\(session.shortID)-\(safeTitle).md"
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            ProjectListView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
        } content: {
            SessionListView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 520)
        } detail: {
            ConversationView(model: model)
        }
        .frame(minWidth: 1100, minHeight: 680)
        .task {
            model.load()
        }
        .alert("AiCliLog", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ProjectListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(model.projects, selection: Binding(
            get: { model.selectedProject },
            set: { project in
                if let project {
                    model.loadSessions(for: project)
                }
            }
        )) { project in
            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text("\(project.sessionCount) sessions")
                    Text(project.sourceLabel)
                    Spacer()
                    Text(project.updatedAt, style: .date)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .tag(project)
        }
        .navigationTitle("Projects")
        .toolbar {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.load()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
    }
}

struct SessionListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(model.sessions, selection: Binding(
            get: { model.selectedSession },
            set: { session in
                if let session {
                    model.loadMessages(for: session)
                }
            }
        )) { session in
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(3)
                HStack(spacing: 10) {
                    Text(session.source.displayName)
                    Text(session.shortID)
                    if !session.model.isEmpty {
                        Text(session.model)
                    }
                    if !session.gitBranch.isEmpty {
                        Text(session.gitBranch)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(session.updatedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .tag(session)
        }
        .navigationTitle(model.selectedProject?.displayName ?? "Sessions")
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching {
                SearchResultsView(model: model)
                Divider()
            }
            header
            Divider()
            if model.visibleQueryGroups.isEmpty {
                if model.isLoading {
                    ProgressView("Loading conversation...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Queries", systemImage: "text.bubble")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(model.visibleQueryGroups) { group in
                                QueryGroupView(group: group, model: model)
                                    .id(group.id)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.pendingSearchMessageID) { _, messageID in
                        guard let messageID else {
                            return
                        }
                        let queryIDs = Set(model.queryGroups.map(\.query.id))
                        let anchor: UnitPoint = queryIDs.contains(messageID) ? .top : .center
                        if let groupID = model.activeSearchGroupID, groupID != messageID {
                            proxy.scrollTo(groupID, anchor: .top)
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(140))
                                guard model.activeSearchMessageID == messageID else {
                                    return
                                }
                                withAnimation {
                                    proxy.scrollTo(messageID, anchor: anchor)
                                }
                                model.pendingSearchMessageID = nil
                            }
                        } else {
                            proxy.scrollTo(messageID, anchor: anchor)
                            model.pendingSearchMessageID = nil
                        }
                    }
                }
            }
        }
        .searchable(text: $model.searchText, isPresented: $model.isSearchPresented, placement: .toolbar, prompt: "Search messages")
        .onChange(of: model.searchText) { _, _ in
            model.updateSearchResults()
        }
        .navigationTitle("Conversation")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.selectedSession?.displayTitle ?? "Select a session")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(model.appVersionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let session = model.selectedSession {
                HStack(spacing: 12) {
                    Text(session.source.displayName)
                    Text(session.shortID)
                    Text(session.updatedAt, format: .dateTime.year().month().day().hour().minute())
                    if !session.model.isEmpty {
                        Text(session.model)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    model.revealSelectedProjectInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    model.copyConversation()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    model.exportConversation()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(model.selectedSession == nil)
                Divider()
                    .frame(height: 16)
                Button {
                    model.expandAllQueries()
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button {
                    model.collapseAllQueries()
                } label: {
                    Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchResultsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let results = model.filteredSearchResults

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(resultCountText(filteredCount: results.count))
                    .font(.headline)
                if model.searchResultLimitHit {
                    Text("showing first \(model.searchResults.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isSearchLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if model.isSearchIndexing {
                    Text("indexing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.searchSourceOptions.count > 1 {
                    Picker("Source", selection: $model.selectedSearchSource) {
                        Text("All Sources").tag(LogSource?.none)
                        ForEach(model.searchSourceOptions) { source in
                            Text(source.displayName).tag(Optional(source))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                if model.searchProjectOptions.count > 1 {
                    Picker("Project", selection: $model.selectedSearchProjectPath) {
                        Text("All Projects").tag(String?.none)
                        ForEach(model.searchProjectOptions) { project in
                            Text(project.displayName).tag(Optional(project.cwd))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            if results.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                    .frame(height: 92)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { result in
                            Button {
                                model.selectSearchResult(result)
                            } label: {
                                SearchResultRow(
                                    result: result,
                                    query: model.trimmedSearchText,
                                    isSelected: result.id == model.activeSearchResultID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func resultCountText(filteredCount: Int) -> String {
        guard model.selectedSearchProjectPath != nil || model.selectedSearchSource != nil else {
            return "\(model.searchResults.count) results"
        }
        return "\(filteredCount) of \(model.searchResults.count) results"
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    let query: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(result.session.source.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(result.project.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(result.session.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let timestamp = result.timestamp {
                    Text(timestamp, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(result.speaker)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(highlightedString(result.snippet, query: query))
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1 : 0.5)
        )
    }
}

struct QueryGroupView: View {
    let group: QueryGroup
    @ObservedObject var model: AppModel

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.expandedQueryIDs.contains(group.id) },
            set: { isExpanded in
                if isExpanded {
                    model.expandedQueryIDs.insert(group.id)
                } else {
                    model.expandedQueryIDs.remove(group.id)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(group.responses) { item in
                    MessageView(
                        item: item,
                        searchText: model.trimmedSearchText,
                        isFocused: item.id == model.activeSearchMessageID
                    )
                    .id(item.id)
                }
            }
            .padding(.top, 12)
            .padding(.leading, 22)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Query")
                        .font(.headline)
                    if let timestamp = group.query.timestamp {
                        Text(timestamp, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(group.responseCount) replies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(highlightedString(group.query.message, query: model.trimmedSearchText))
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .id(group.query.id)
            .background(group.id == model.activeSearchGroupID ? Color.yellow.opacity(0.16) : Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(group.id == model.activeSearchGroupID ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: group.id == model.activeSearchGroupID ? 1 : 0.5)
            )
        }
    }
}

struct MessageView: View {
    let item: CleanMessage
    let searchText: String
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.speaker)
                    .font(.headline)
                if let timestamp = item.timestamp {
                    Text(timestamp, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(highlightedString(item.message, query: searchText))
                .textSelection(.enabled)
                .font(.body)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(messageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isFocused ? 1 : 0.5)
        )
    }

    private var messageBackground: Color {
        if isFocused {
            return Color.yellow.opacity(0.16)
        }
        return item.speaker == "You" ? Color.accentColor.opacity(0.10) : Color(nsColor: .textBackgroundColor)
    }
}

@main
struct AiCliLogApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("AiCliLog", id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Actions") {
                Button {
                    model.load()
                } label: {
                    Label("Refresh Data", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button {
                    model.beginSearch()
                } label: {
                    Label("Search Messages", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        MenuBarExtra("AiCliLog", systemImage: "magnifyingglass.circle") {
            Text(model.appVersionLabel)
            Divider()
            Button {
                openWindow(id: "main")
                model.showMainWindow()
            } label: {
                Label("Show App", systemImage: "macwindow")
            }
            Button {
                model.restartApp()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            Divider()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }
}
