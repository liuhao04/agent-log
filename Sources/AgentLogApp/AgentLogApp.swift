import AppKit
import CSQLite
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let searchLogger = Logger(subsystem: "io.github.agentlog", category: "search")

enum LogSource: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case codex
    case claude
    case cowork

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .cowork:
            return "Claude Cowork"
        }
    }
}

struct ProjectSummary: Identifiable, Hashable, Sendable, Codable {
    // `projectKey` is the unique grouping key — for Codex it equals `cwd`; for
    // Claude/Cowork it's the on-disk encoded directory path under
    // `~/.claude/projects/<encoded>` (so two separate encoded dirs that happen
    // to hold the same internal `event.cwd` — e.g. after the user migrated a
    // project — show up as distinct projects).
    var id: String { projectKey }
    let projectKey: String
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

struct CodexSession: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(source.rawValue):\(projectKey):\(sessionID)" }
    let sessionID: String
    let source: LogSource
    let projectKey: String
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

struct CleanMessage: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let timestamp: Date?
    let speaker: String
    let message: String
}

enum QueryGroupKind: Hashable, Sendable {
    case query
    case meta
}

struct QueryGroup: Identifiable, Hashable, Sendable {
    let id: String
    let kind: QueryGroupKind
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
        guard isAvailable else { return [] }
        return try withDatabase { db in
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
                    projectKey: columnText(stmt, 0),
                    cwd: columnText(stmt, 0),
                    sessionCount: Int(sqlite3_column_int(stmt, 1)),
                    updatedAt: dateFromUnix(stmt, 2),
                    sources: [.codex]
                )
            }
        }
    }

    func sessions(cwd: String, limit: Int = 100) throws -> [CodexSession] {
        guard isAvailable else { return [] }
        return try withDatabase { db in
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
                    projectKey: columnText(stmt, 1),
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
        guard isAvailable else { return [] }
        return try withDatabase { db in
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
                    projectKey: columnText(stmt, 1),
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

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw CodexStoreError.databaseMissing(databasePath)
        }

        // Open as immutable read-only via URI so we never touch the user's
        // Codex sqlite WAL/SHM sidecars or contend for locks with a running
        // Codex CLI process.
        let escaped = databasePath
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
        let uri = "file:\(escaped)?immutable=1"

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            if db != nil { sqlite3_close(db) }
            throw CodexStoreError.databaseOpenFailed(message)
        }
        defer { sqlite3_close(db) }
        _ = try? execute(db: db, sql: "pragma busy_timeout = 5000", bind: { _ in }, map: { _ in () })
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
        // Group by projectKey (encoded-dir path) so two separate dirs under
        // `~/.claude/projects/` that happen to share `event.cwd` (e.g. after a
        // project moved) stay as distinct projects. cwd shown in the row is
        // the cwd from the session with the latest updatedAt — that's the
        // closest signal to "where this project actually lives now".
        var grouped: [String: (count: Int, updatedAt: Date, cwd: String, cwdAt: Date)] = [:]
        for session in sessions {
            let existing = grouped[session.projectKey]
            let useNewCwd = (existing?.cwdAt ?? .distantPast) < session.updatedAt
            grouped[session.projectKey] = (
                count: (existing?.count ?? 0) + 1,
                updatedAt: max(existing?.updatedAt ?? .distantPast, session.updatedAt),
                cwd: useNewCwd ? session.cwd : (existing?.cwd ?? session.cwd),
                cwdAt: useNewCwd ? session.updatedAt : (existing?.cwdAt ?? session.updatedAt)
            )
        }
        return grouped.map { key, value in
            ProjectSummary(projectKey: key, cwd: value.cwd, sessionCount: value.count, updatedAt: value.updatedAt, sources: [.claude])
        }
        .sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.projectKey < right.projectKey
            }
            return left.updatedAt > right.updatedAt
        }
    }

    func sessions(projectKey: String) throws -> [CodexSession] {
        try sessions(projectKey: projectKey, from: allSessions())
    }

    func sessions(projectKey: String, from sessions: [CodexSession]) throws -> [CodexSession] {
        sessions
            .filter { $0.projectKey == projectKey }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.sessionID > right.sessionID
                }
                return left.updatedAt > right.updatedAt
            }
    }

    func allSessions(cacheOnly: Bool = false) throws -> [CodexSession] {
        var sessions: [CodexSession] = []
        let cache = ClaudeSummaryCache.shared
        var seenPaths: Set<String> = []
        for file in try sessionFiles() {
            try Task.checkCancellation()
            seenPaths.insert(file.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if let cached = cache.lookup(path: file.path, mtime: mtime, size: size) {
                if let session = cached { sessions.append(session) }
                continue
            }
            if cacheOnly {
                // Skip files we'd need to parse from disk; the follow-up
                // full-pass load() will pick them up.
                continue
            }
            let session = sessionSummary(for: file)
            cache.store(path: file.path, mtime: mtime, size: size, session: session)
            if let session { sessions.append(session) }
        }
        if !cacheOnly {
            cache.evict(scopePrefix: projectsPath.path, keeping: seenPaths)
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
                    let baseSpeaker = speaker(for: event),
                    let message = cleanClaudeMessage(event.message?.content),
                    !message.isEmpty
                else {
                    return nil
                }
                let resolvedSpeaker = (baseSpeaker == "You" && isClaudeMetaUserMessage(message)) ? "System" : baseSpeaker
                return CleanMessage(
                    id: "\(session.id):\(lineNumber)",
                    timestamp: parseISO8601(event.timestamp),
                    speaker: resolvedSpeaker,
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
        let prefixText = readSummaryPrefix(url) ?? ""
        let tailText = readSummarySuffix(url, skipping: prefixText.utf8.count)
        let text = prefixText.isEmpty ? tailText : (tailText.isEmpty ? prefixText : prefixText + "\n" + tailText)
        guard !text.isEmpty else {
            return nil
        }

        let decoder = JSONDecoder()
        var cwd: String?
        var sessionID = url.deletingPathExtension().lastPathComponent
        var firstQueryTitle: String?
        var renameTitle: String?
        var updatedAt = fileModificationDate(url)
        var gitBranch = ""

        for line in text.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let event = try? decoder.decode(ClaudeEvent.self, from: data)
            else {
                continue
            }
            // Take the LATEST non-nil cwd, not the first. The suffix scan reads
            // the tail of the file, so this ends up reflecting where the user
            // most recently resumed this session — which is the closest thing
            // to "the project's current real directory".
            if let c = event.cwd { cwd = c }
            sessionID = event.sessionId ?? sessionID
            if gitBranch.isEmpty {
                gitBranch = event.gitBranch ?? ""
            }
            if let timestamp = event.timestamp.flatMap(parseISO8601) {
                updatedAt = max(updatedAt ?? .distantPast, timestamp)
            }
            guard event.type == "user",
                  let message = cleanClaudeMessage(event.message?.content),
                  !message.isEmpty
            else {
                continue
            }
            if isClaudeMetaUserMessage(message) {
                if let renamed = extractClaudeRenameTitle(message) {
                    renameTitle = renamed
                }
                continue
            }
            if firstQueryTitle == nil {
                firstQueryTitle = message.replacingOccurrences(of: "\n", with: " ")
            }
        }

        // The prefix+suffix scan misses any rename system-reminder that lives
        // in the middle of a large session. Sweep the whole file when there's
        // a gap so a mid-session rename still wins over firstQueryTitle.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > 2 * summaryReadLimit, let fullRename = findLastClaudeRenameTitle(url) {
            renameTitle = fullRename
        }

        let title = renameTitle ?? firstQueryTitle

        guard let cwd else {
            return nil
        }

        // projectKey = the encoded directory's full path on disk. Two distinct
        // encoded dirs (e.g. after a project moved between locations) stay
        // separate projects even when their internal `event.cwd` matches.
        let projectKey = url.deletingLastPathComponent().path

        return CodexSession(
            sessionID: sessionID,
            source: .claude,
            projectKey: projectKey,
            cwd: cwd,
            title: String((title ?? sessionID).prefix(120)),
            transcriptPath: url.path,
            updatedAt: updatedAt ?? .distantPast,
            model: "Claude Code",
            gitBranch: gitBranch
        )
    }

    private func findLastClaudeRenameTitle(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        var carry = Data()
        var last: String?
        let decoder = JSONDecoder()

        func scan(line: String) {
            // The raw JSONL line escapes quotes inside the content string,
            // so we must JSON-decode the event before running the rename regex.
            guard line.contains("named this session"),
                  let data = line.data(using: .utf8),
                  let event = try? decoder.decode(ClaudeEvent.self, from: data),
                  event.type == "user",
                  let message = cleanClaudeMessage(event.message?.content),
                  let title = extractClaudeRenameTitle(message)
            else { return }
            last = title
        }

        while let data = try? handle.read(upToCount: chunkSize), !data.isEmpty {
            var buf = carry
            buf.append(data)
            guard let lastNLIdx = buf.lastIndex(of: 0x0A) else {
                carry = buf
                continue
            }
            let head = buf.subdata(in: 0..<(lastNLIdx + 1))
            carry = buf.subdata(in: (lastNLIdx + 1)..<buf.count)
            if let text = String(data: head, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    scan(line: String(line))
                }
            }
        }
        if !carry.isEmpty, let text = String(data: carry, encoding: .utf8) {
            scan(line: text)
        }
        return last
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

    private func readSummarySuffix(_ url: URL, skipping prefixBytes: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > prefixBytes else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let tailLimit = summaryReadLimit
        let offset = max(prefixBytes, fileSize - tailLimit)
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return ""
        }
        guard let data = try? handle.read(upToCount: fileSize - offset), !data.isEmpty else {
            return ""
        }
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        // discard the first (possibly partial) line so JSON parse doesn't fail mid-record
        if let nl = raw.firstIndex(of: "\n") {
            return String(raw[raw.index(after: nl)...])
        }
        return ""
    }
}

private struct CoworkSidecar: Decodable {
    let sessionId: String?
    let cliSessionId: String?
    let title: String?
    let cwd: String?
    let userSelectedFolders: [String]?
    let createdAt: Double?
    let lastActivityAt: Double?
    let model: String?
    let isArchived: Bool?
}

final class CoworkStore {
    private let claudeAppHome: URL
    private var sessionsRoot: URL {
        claudeAppHome.appendingPathComponent("local-agent-mode-sessions")
    }

    init(claudeAppHome: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude")) {
        self.claudeAppHome = claudeAppHome
    }

    func projects(from sessions: [CodexSession]) -> [ProjectSummary] {
        // cwd resolution uses the latest session — see ClaudeStore.projects for
        // the rationale (post-mv jsonls can have stale internal cwd).
        var grouped: [String: (count: Int, updatedAt: Date, cwd: String, cwdAt: Date)] = [:]
        for session in sessions {
            let existing = grouped[session.projectKey]
            let useNewCwd = (existing?.cwdAt ?? .distantPast) < session.updatedAt
            grouped[session.projectKey] = (
                count: (existing?.count ?? 0) + 1,
                updatedAt: max(existing?.updatedAt ?? .distantPast, session.updatedAt),
                cwd: useNewCwd ? session.cwd : (existing?.cwd ?? session.cwd),
                cwdAt: useNewCwd ? session.updatedAt : (existing?.cwdAt ?? session.updatedAt)
            )
        }
        return grouped.map { key, value in
            ProjectSummary(projectKey: key, cwd: value.cwd, sessionCount: value.count, updatedAt: value.updatedAt, sources: [.cowork])
        }
        .sorted { left, right in
            if left.updatedAt == right.updatedAt {
                return left.projectKey < right.projectKey
            }
            return left.updatedAt > right.updatedAt
        }
    }

    func sessions(projectKey: String, from sessions: [CodexSession]) -> [CodexSession] {
        sessions
            .filter { $0.projectKey == projectKey }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.sessionID > right.sessionID
                }
                return left.updatedAt > right.updatedAt
            }
    }

    func allSessions(cacheOnly: Bool = false) throws -> [CodexSession] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            return []
        }

        var results: [CodexSession] = []
        let decoder = JSONDecoder()
        let cache = ClaudeSummaryCache.shared
        var seenPaths: Set<String> = []

        // Layout: <root>/<userId>/<workspaceId>/local_<sessionId>.json
        let userDirs = (try? fileManager.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for userDir in userDirs {
            try Task.checkCancellation()
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: userDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let workspaceDirs = (try? fileManager.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for workspaceDir in workspaceDirs {
                try Task.checkCancellation()
                var wsIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: workspaceDir.path, isDirectory: &wsIsDir), wsIsDir.boolValue else { continue }

                let entries = (try? fileManager.contentsOfDirectory(at: workspaceDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for entry in entries {
                    guard entry.pathExtension == "json",
                          entry.lastPathComponent.hasPrefix("local_"),
                          !entry.lastPathComponent.hasSuffix(".bak.json"),
                          !entry.lastPathComponent.hasSuffix(".json.bak")
                    else { continue }

                    seenPaths.insert(entry.path)
                    let attrs = try? fileManager.attributesOfItem(atPath: entry.path)
                    let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    if let cached = cache.lookup(path: entry.path, mtime: mtime, size: size) {
                        if let session = cached { results.append(session) }
                        continue
                    }
                    if cacheOnly { continue }

                    guard let data = try? Data(contentsOf: entry),
                          let sidecar = try? decoder.decode(CoworkSidecar.self, from: data),
                          let cliSessionId = sidecar.cliSessionId, !cliSessionId.isEmpty
                    else {
                        cache.store(path: entry.path, mtime: mtime, size: size, session: nil)
                        continue
                    }

                    // Inner session directory holds the JSONL transcript under .claude/projects/<encoded>/<cliSessionId>.jsonl
                    let innerDirName = entry.deletingPathExtension().lastPathComponent
                    let innerDir = workspaceDir.appendingPathComponent(innerDirName, isDirectory: true)
                    let projectsDir = innerDir.appendingPathComponent(".claude/projects", isDirectory: true)
                    guard let transcriptURL = locateTranscript(in: projectsDir, cliSessionId: cliSessionId) else {
                        cache.store(path: entry.path, mtime: mtime, size: size, session: nil)
                        continue
                    }

                    let cwd = (sidecar.userSelectedFolders?.first(where: { !$0.isEmpty })) ?? sidecar.cwd ?? innerDir.path
                    let updatedAt = sidecar.lastActivityAt
                        .map { Date(timeIntervalSince1970: $0 / 1000) }
                        ?? fileModificationDate(transcriptURL)
                        ?? .distantPast
                    let title = (sidecar.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? cliSessionId
                    let model = (sidecar.model?.isEmpty == false ? sidecar.model! : "Claude Cowork")

                    // projectKey = the inner .claude/projects/<encoded> dir
                    // path, mirroring ClaudeStore. Each cowork session lives in
                    // its own innerDir though, so projectKey is effectively
                    // unique per-cowork-session unless multiple sessions share
                    // the same workspace path.
                    let projectKey = transcriptURL.deletingLastPathComponent().path

                    let session = CodexSession(
                        sessionID: cliSessionId,
                        source: .cowork,
                        projectKey: projectKey,
                        cwd: cwd,
                        title: String(title.prefix(120)),
                        transcriptPath: transcriptURL.path,
                        updatedAt: updatedAt,
                        model: model,
                        gitBranch: ""
                    )
                    cache.store(path: entry.path, mtime: mtime, size: size, session: session)
                    results.append(session)
                }
            }
        }
        if !cacheOnly {
            cache.evict(scopePrefix: sessionsRoot.path, keeping: seenPaths)
        }
        return results
    }

    private func locateTranscript(in projectsDir: URL, cliSessionId: String) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: projectsDir.path) else { return nil }
        guard let enumerator = fileManager.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let target = "\(cliSessionId).jsonl"
        for case let url as URL in enumerator {
            if url.lastPathComponent == target {
                return url
            }
        }
        return nil
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
        return base.appendingPathComponent("AgentLog", isDirectory: true)
    }

    private var databaseURL: URL {
        supportDirectory
            .appendingPathComponent("search-index.sqlite")
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

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return ([], false)
        }

        let db = try openDatabase(createIfNeeded: false)
        defer { sqlite3_close(db) }

        // projectKey isn't stored in the search index schema (would need a
        // migration). Derive it the same way the stores do: Codex uses cwd,
        // Claude/Cowork use the transcript file's parent directory.
        let projectByKey = Dictionary(uniqueKeysWithValues: projects.map { ($0.projectKey, $0) })
        let rows = try searchRows(query: trimmed, limit: limit + 1, db: db)
        let results = rows.map { row -> SearchResult in
            let source = LogSource(rawValue: row.source) ?? .codex
            let projectKey: String
            switch source {
            case .codex:
                projectKey = row.cwd
            case .claude, .cowork:
                projectKey = URL(fileURLWithPath: row.transcriptPath).deletingLastPathComponent().path
            }
            let session = CodexSession(
                sessionID: row.sessionID,
                source: source,
                projectKey: projectKey,
                cwd: row.cwd,
                title: row.title,
                transcriptPath: row.transcriptPath,
                updatedAt: Date(timeIntervalSince1970: row.updatedAt),
                model: row.model,
                gitBranch: row.gitBranch
            )
            let project = projectByKey[projectKey] ?? ProjectSummary(
                projectKey: projectKey,
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
        case .claude, .cowork:
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
            projectKey: session.projectKey,
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

private let claudeMetaUserTags: Set<String> = [
    "local-command-caveat",
    "command-name",
    "command-message",
    "command-args",
    "command-stdout",
    "command-stderr",
    "local-command-stdout",
    "local-command-stderr",
    "bash-input",
    "bash-stdout",
    "bash-stderr",
    "system-reminder"
]

private func isClaudeMetaUserMessage(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<"), let tagEnd = trimmed.firstIndex(of: ">") else {
        return false
    }
    let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<tagEnd]
    let tag = inner.split(separator: " ", maxSplits: 1).first.map(String.init) ?? String(inner)
    return claudeMetaUserTags.contains(tag)
}

private func extractClaudeRenameTitle(_ text: String) -> String? {
    guard text.contains("named this session") else {
        return nil
    }
    guard let regex = try? NSRegularExpression(
        pattern: #"named this session\s+"([^"]+)""#,
        options: []
    ) else {
        return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard
        let match = regex.firstMatch(in: text, options: [], range: range),
        match.numberOfRanges >= 2,
        let captured = Range(match.range(at: 1), in: text)
    else {
        return nil
    }
    let title = text[captured].trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
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
    var pendingMeta: [CleanMessage] = []

    func flushQuery() {
        guard let query = currentQuery else { return }
        groups.append(QueryGroup(id: query.id, kind: .query, query: query, responses: currentResponses))
        currentQuery = nil
        currentResponses = []
    }

    func flushMeta() {
        guard let first = pendingMeta.first else { return }
        let label = CleanMessage(
            id: "\(first.id):meta",
            timestamp: first.timestamp,
            speaker: "System",
            message: "System messages × \(pendingMeta.count)"
        )
        groups.append(QueryGroup(id: label.id, kind: .meta, query: label, responses: pendingMeta))
        pendingMeta = []
    }

    for message in messages {
        if message.speaker == "System" {
            pendingMeta.append(message)
            continue
        }
        flushMeta()
        if message.speaker == "You" {
            flushQuery()
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
    flushQuery()
    flushMeta()
    return groups
}

final class ClaudeSummaryCache: @unchecked Sendable {
    static let shared = ClaudeSummaryCache()
    private struct Entry {
        let mtime: Date
        let size: Int64
        let session: CodexSession?
    }
    private struct DiskEntry: Codable {
        let path: String
        let mtime: Date
        let size: Int64
        let session: CodexSession?
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private var didLoad = false
    private var dirty = false
    private var saveScheduled = false
    private static let saveQueue = DispatchQueue(label: "io.github.agentlog.summary-cache.save", qos: .utility)

    private static let diskURL: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("io.github.agentlog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-cache-v1.json")
    }()

    func lookup(path: String, mtime: Date, size: Int64) -> CodexSession?? {
        lock.lock(); defer { lock.unlock() }
        loadFromDiskLocked()
        guard let e = entries[path],
              e.size == size,
              abs(e.mtime.timeIntervalSince1970 - mtime.timeIntervalSince1970) < 0.001
        else { return nil }
        return .some(e.session)
    }

    func store(path: String, mtime: Date, size: Int64, session: CodexSession?) {
        lock.lock()
        loadFromDiskLocked()
        entries[path] = Entry(mtime: mtime, size: size, session: session)
        dirty = true
        let shouldSchedule = !saveScheduled
        if shouldSchedule { saveScheduled = true }
        lock.unlock()
        if shouldSchedule { scheduleSave() }
    }

    func evict(scopePrefix: String, keeping paths: Set<String>) {
        lock.lock()
        loadFromDiskLocked()
        let before = entries.count
        entries = entries.filter { key, _ in
            if key.hasPrefix(scopePrefix) {
                return paths.contains(key)
            }
            return true
        }
        let changed = entries.count != before
        if changed { dirty = true }
        let shouldSchedule = changed && !saveScheduled
        if shouldSchedule { saveScheduled = true }
        lock.unlock()
        if shouldSchedule { scheduleSave() }
    }

    func invalidate(path: String) {
        lock.lock()
        loadFromDiskLocked()
        let removed = entries.removeValue(forKey: path) != nil
        if removed { dirty = true }
        let shouldSchedule = removed && !saveScheduled
        if shouldSchedule { saveScheduled = true }
        lock.unlock()
        if shouldSchedule { scheduleSave() }
    }

    private func loadFromDiskLocked() {
        guard !didLoad else { return }
        didLoad = true
        guard let url = Self.diskURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        guard let arr = try? decoder.decode([DiskEntry].self, from: data) else { return }
        for e in arr {
            entries[e.path] = Entry(mtime: e.mtime, size: e.size, session: e.session)
        }
    }

    private func scheduleSave() {
        Self.saveQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.flushIfDirty()
        }
    }

    private func flushIfDirty() {
        lock.lock()
        saveScheduled = false
        guard dirty, let url = Self.diskURL else { lock.unlock(); return }
        dirty = false
        let snapshot = entries.map {
            DiskEntry(path: $0.key, mtime: $0.value.mtime, size: $0.value.size, session: $0.value.session)
        }
        lock.unlock()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.github.agentlog.fswatch")
    var onChange: (([String]) -> Void)?

    func start(paths: [String]) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let array = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let slice = Array(array.prefix(Int(count)))
            watcher.onChange?(slice)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
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
    @Published var pendingScrollEdge: ScrollEdge?
    @Published var pendingScrollGroupID: String?
    @Published var lastClickedGroupID: String?
    var pendingScrollAnimated: Bool = true

    // Per-project view state: selected session + which queries are expanded.
    // (Scroll-anchor restore was tried but caused session-switch lag, so it's
    // currently disabled — the scroll lands at the bottom like a normal
    // session click. The session + expansion state still survives.)
    struct ProjectViewState {
        var sessionID: String?
        var expandedQueryIDs: Set<String>
    }
    private var projectViewStates: [String: ProjectViewState] = [:]

    func captureCurrentProjectState() {
        guard let key = selectedProject?.projectKey else { return }
        projectViewStates[key] = ProjectViewState(
            sessionID: selectedSession?.id,
            expandedQueryIDs: expandedQueryIDs
        )
    }

    enum ScrollEdge { case top, bottom }

    func requestScroll(to edge: ScrollEdge, animated: Bool = true) {
        pendingScrollAnimated = animated
        pendingScrollEdge = edge
    }

    func requestScroll(toGroup groupID: String, animated: Bool = true) {
        pendingScrollAnimated = animated
        pendingScrollGroupID = groupID
    }

    private var knownClaudeSessions: [CodexSession] = []
    private var loadTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchIndexTask: Task<Void, Never>?
    private let searchResultLimit = 500

    private let fsWatcher = FileSystemWatcher()
    private var debounceTask: Task<Void, Never>?
    private var pendingChangeCount: Int = 0
    private var watcherStarted = false
    private let debounceWindow: Double = 10.0

    private struct LoadSnapshot: Sendable, Codable {
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
        for result in searchResults where !seen.contains(result.project.projectKey) {
            if let selectedSearchSource, result.session.source != selectedSearchSource {
                continue
            }
            seen.insert(result.project.projectKey)
            options.append(result.project)
        }
        return options
    }

    var filteredSearchResults: [SearchResult] {
        searchResults.filter { result in
            if let selectedSearchSource, result.session.source != selectedSearchSource {
                return false
            }
            if let selectedSearchProjectPath, result.project.projectKey != selectedSearchProjectPath {
                return false
            }
            return true
        }
    }

    var searchSourceOptions: [LogSource] {
        LogSource.allCases.filter { source in
            searchResults.contains { result in
                if let selectedSearchProjectPath, result.project.projectKey != selectedSearchProjectPath {
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
        let preferredProjectPath = selectedProject?.projectKey
        let preferredSessionID = selectedSession?.id

        loadTask = Task { [weak self, preferredProjectPath, preferredSessionID] in
            do {
                // Phase 1: serve from the persisted last-snapshot for an
                // instant first paint — zero IO beyond a single JSON read.
                let lastJob = Task.detached(priority: .userInitiated) {
                    Self.loadLastSnapshot()
                }
                if let last = await lastJob.value, !Task.isCancelled, !last.projects.isEmpty {
                    self?.apply(last)
                    self?.isLoading = false
                }

                // Phase 2: full scan — fills in new/changed files and evicts
                // stale cache entries.
                let job = Task.detached(priority: .userInitiated) {
                    try Self.loadSnapshot(
                        preferredProjectPath: preferredProjectPath,
                        preferredSessionID: preferredSessionID,
                        includeClaude: true
                    )
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(snapshot)
                self?.isLoading = false
                self?.refreshSearchIndexInBackground()
                self?.updateSearchResults()
                Task.detached(priority: .background) {
                    Self.saveLastSnapshot(snapshot)
                }
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

    func startWatchingIfNeeded() {
        guard !watcherStarted else { return }
        watcherStarted = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex").path
        let claudeProjects = home.appendingPathComponent(".claude/projects").path
        fsWatcher.onChange = { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.handleFileSystemChange(paths: paths)
            }
        }
        fsWatcher.start(paths: [codexDir, claudeProjects])
    }

    private func handleFileSystemChange(paths: [String]) {
        // Only `.jsonl` log files matter. FSEvents on the watched directories
        // also fire for `.DS_Store`, lockfiles, directory mtime bumps, etc.
        // — those should not trigger a reload that jumps the user's selection.
        let logPaths = paths.filter { $0.hasSuffix(".jsonl") }
        guard !logPaths.isEmpty else { return }
        for path in logPaths {
            ClaudeSummaryCache.shared.invalidate(path: path)
        }
        pendingChangeCount += 1
        scheduleDebouncedReload()
    }

    private func scheduleDebouncedReload() {
        debounceTask?.cancel()
        let window = debounceWindow
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pendingChangeCount = 0
                self.load()
            }
        }
    }

    func loadSessions(for project: ProjectSummary) {
        // Snapshot the project we're leaving so we can rehydrate it later.
        captureCurrentProjectState()
        let restoring = projectViewStates[project.projectKey]

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
        let preferredSessionID = restoring?.sessionID

        sessionTask = Task { [weak self, project, preferredSessionID, restoring] in
            do {
                let job = Task.detached(priority: .userInitiated) {
                    try Self.sessionSnapshot(
                        project: project,
                        preferredSessionID: preferredSessionID,
                        includeClaude: true,
                        knownClaudeSessions: cachedClaudeSessions
                    )
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
                guard !Task.isCancelled else {
                    return
                }
                self?.apply(snapshot)
                // Restore expanded queries only when the cached session still
                // resolves to the same session id (otherwise the ids are stale).
                let matched = restoring?.sessionID != nil
                    && restoring?.sessionID == snapshot.selectedSession?.id
                if matched, let cachedExpanded = restoring?.expandedQueryIDs {
                    self?.expandedQueryIDs = cachedExpanded
                }
                self?.isLoading = false
                // Land at the latest turn like a normal session click.
                self?.requestScroll(to: .bottom, animated: false)
                _ = matched
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
                self?.requestScroll(to: .bottom, animated: false)
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
                   !response.results.contains(where: { $0.project.projectKey == selected }) {
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
        let project = projects.first { $0.projectKey == result.project.projectKey } ?? result.project
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
        let previousSessionID = selectedSession?.id
        projects = snapshot.projects
        selectedProject = snapshot.selectedProject
        sessions = snapshot.sessions
        selectedSession = snapshot.selectedSession
        messages = snapshot.messages
        if !snapshot.knownClaudeSessions.isEmpty {
            knownClaudeSessions = snapshot.knownClaudeSessions
        }
        reconcileExpandedQueryIDs(previousSessionID: previousSessionID)
        clearActiveSearchTarget()
    }

    private func apply(_ snapshot: SessionSnapshot) {
        let previousSessionID = selectedSession?.id
        selectedProject = snapshot.project
        sessions = snapshot.sessions
        selectedSession = snapshot.selectedSession
        messages = snapshot.messages
        reconcileExpandedQueryIDs(previousSessionID: previousSessionID)
        clearActiveSearchTarget()
    }

    private func apply(_ snapshot: MessageSnapshot) {
        let previousSessionID = selectedSession?.id
        selectedSession = snapshot.session
        messages = snapshot.messages
        reconcileExpandedQueryIDs(previousSessionID: previousSessionID)
        clearActiveSearchTarget()
    }

    private func reconcileExpandedQueryIDs(previousSessionID: String?) {
        if selectedSession?.id != previousSessionID {
            expandedQueryIDs = []
            return
        }
        guard !expandedQueryIDs.isEmpty else { return }
        let liveIDs = Set(queryGroups.map(\.id))
        expandedQueryIDs.formIntersection(liveIDs)
    }

    private nonisolated static func loadSnapshot(
        preferredProjectPath: String?,
        preferredSessionID: String?,
        includeClaude: Bool,
        cacheOnly: Bool = false
    ) throws -> LoadSnapshot {
        try Task.checkCancellation()
        let store = CodexStore()
        var projectItems = try store.projects(limit: 500)
        var knownClaudeSessions: [CodexSession] = []
        if includeClaude {
            let claudeStore = ClaudeStore()
            knownClaudeSessions = try claudeStore.allSessions(cacheOnly: cacheOnly)
            projectItems += try claudeStore.projects(from: knownClaudeSessions)
            let coworkStore = CoworkStore()
            let coworkSessions = try coworkStore.allSessions(cacheOnly: cacheOnly)
            knownClaudeSessions += coworkSessions
            projectItems += coworkStore.projects(from: coworkSessions)
        }
        let projects = mergedProjects(projectItems)
        try Task.checkCancellation()
        let selectedProject = projects.first { $0.projectKey == preferredProjectPath } ?? projects.first
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
            projectKey: project.projectKey,
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

    private nonisolated static let lastSnapshotURL: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("io.github.agentlog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-snapshot-v1.json")
    }()

    private nonisolated static func loadLastSnapshot() -> LoadSnapshot? {
        guard let url = lastSnapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LoadSnapshot.self, from: data)
    }

    private nonisolated static func saveLastSnapshot(_ snapshot: LoadSnapshot) {
        guard let url = lastSnapshotURL else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func projectSessions(
        projectKey: String,
        includeClaude: Bool,
        knownClaudeSessions: [CodexSession] = []
    ) throws -> [CodexSession] {
        try Task.checkCancellation()
        let store = CodexStore()
        // Codex's projectKey is identical to cwd, so the SQL filter is the same.
        var sessions = try store.sessions(cwd: projectKey)
        if includeClaude {
            let claudeStore = ClaudeStore()
            if knownClaudeSessions.isEmpty {
                sessions += try claudeStore.sessions(projectKey: projectKey)
                let coworkSessions = try CoworkStore().allSessions()
                sessions += CoworkStore().sessions(projectKey: projectKey, from: coworkSessions)
            } else {
                sessions += try claudeStore.sessions(projectKey: projectKey, from: knownClaudeSessions)
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
        case .claude, .cowork:
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
        let claudeAndCowork: [CodexSession]
        if knownClaudeSessions.isEmpty {
            claudeAndCowork = try ClaudeStore().allSessions() + CoworkStore().allSessions()
        } else {
            claudeAndCowork = knownClaudeSessions
        }
        try Task.checkCancellation()
        return codexSessions + claudeAndCowork
    }

    private nonisolated static func mergedProjects(_ items: [ProjectSummary]) -> [ProjectSummary] {
        // Merge by projectKey so a single cwd that's reachable via multiple
        // sources (Codex + Claude for the same real cwd) folds into one row,
        // but two Claude encoded dirs that share a cwd stay separate.
        var grouped: [String: (count: Int, updatedAt: Date, sources: Set<LogSource>, cwd: String)] = [:]
        for item in items {
            var existing = grouped[item.projectKey] ?? (count: 0, updatedAt: .distantPast, sources: [], cwd: item.cwd)
            existing.count += item.sessionCount
            existing.updatedAt = max(existing.updatedAt, item.updatedAt)
            existing.sources.formUnion(item.sources)
            grouped[item.projectKey] = existing
        }
        return grouped.map { key, value in
            ProjectSummary(
                projectKey: key,
                cwd: value.cwd,
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
            model.startWatchingIfNeeded()
        }
        .alert("AgentLog", isPresented: Binding(
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
        List(model.projects, selection: Binding<String?>(
            get: { model.selectedProject?.id },
            set: { id in
                if let id, let project = model.projects.first(where: { $0.id == id }) {
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
            .tag(project.id)
        }
        .navigationTitle("Projects")
        .toolbar {
            Button {
                model.load()
            } label: {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isLoading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(model.appVersionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}

struct SessionListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Bind selection by stable ID, not the whole struct. CodexSession's
        // Hashable includes `updatedAt`, which changes whenever the underlying
        // jsonl is appended — that would otherwise make SwiftUI think the
        // current selection has disappeared and jump it to another row.
        List(model.sessions, selection: Binding<String?>(
            get: { model.selectedSession?.id },
            set: { id in
                if let id, let session = model.sessions.first(where: { $0.id == id }) {
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
            .tag(session.id)
        }
        .navigationTitle(model.selectedProject?.displayName ?? "Sessions")
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel

    private func performPendingScroll(proxy: ScrollViewProxy) {
        guard let edge = model.pendingScrollEdge else { return }
        let animated = model.pendingScrollAnimated
        let groups = model.visibleQueryGroups
        guard !groups.isEmpty else { return }
        let targetID = edge == .top ? groups.first!.id : groups.last!.id
        let anchor: UnitPoint = edge == .top ? .top : .bottom
        model.pendingScrollEdge = nil
        let scroll = {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(targetID, anchor: anchor)
                }
            } else {
                proxy.scrollTo(targetID, anchor: anchor)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            scroll()
            if edge == .bottom {
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(targetID, anchor: anchor)
            }
        }
    }

    @ViewBuilder
    private var scrollBody: some View {
        if model.visibleQueryGroups.isEmpty {
            if model.isLoading {
                ProgressView("Loading conversation...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Queries", systemImage: "text.bubble")
            }
        } else {
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
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching {
                SearchResultsView(model: model)
                Divider()
            }
            header
            Divider()
            ScrollViewReader { proxy in
                scrollBody
                .onChange(of: model.visibleQueryGroups.map(\.id)) { _, _ in
                    // Groups just populated (e.g. session opened from sidebar):
                    // honour any pending scroll request that was set before the
                    // ScrollView existed.
                    guard model.pendingScrollEdge != nil else { return }
                    performPendingScroll(proxy: proxy)
                }
                .onChange(of: model.pendingScrollEdge) { _, edge in
                    guard edge != nil else { return }
                    performPendingScroll(proxy: proxy)
                }
                .onChange(of: model.pendingScrollGroupID) { _, gid in
                    guard let gid else { return }
                    let animated = model.pendingScrollAnimated
                    model.pendingScrollGroupID = nil
                    // Defer one tick so the collapsed view has finished its
                    // layout pass before we re-anchor scroll position.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(16))
                        if animated {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(gid, anchor: .top)
                            }
                        } else {
                            proxy.scrollTo(gid, anchor: .top)
                        }
                    }
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
        .searchable(text: $model.searchText, isPresented: $model.isSearchPresented, placement: .toolbar, prompt: "Search messages")
        .onChange(of: model.searchText) { _, _ in
            model.updateSearchResults()
        }
        .navigationTitle("Conversation")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.selectedSession?.displayTitle ?? "Select a session")
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Divider()
                    .frame(height: 16)
                Button {
                    model.requestScroll(to: .top)
                } label: {
                    Label("Top", systemImage: "arrow.up.to.line")
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.visibleQueryGroups.isEmpty)
                Button {
                    model.requestScroll(to: .bottom)
                } label: {
                    Label("End", systemImage: "arrow.down.to.line")
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.visibleQueryGroups.isEmpty)
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
                            Text(project.displayName).tag(Optional(project.projectKey))
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
    @State private var isQueryTextExpanded = false

    private var isResponseExpanded: Bool {
        model.expandedQueryIDs.contains(group.id)
    }

    private var isLastClicked: Bool {
        model.lastClickedGroupID == group.id
    }

    private func markClicked() {
        model.lastClickedGroupID = group.id
    }

    private func toggleResponseExpanded() {
        markClicked()
        if isResponseExpanded {
            model.expandedQueryIDs.remove(group.id)
        } else {
            model.expandedQueryIDs.insert(group.id)
        }
    }

    // Show the "Show more / Show less" toggle when the query text is long
    // enough to truncate at 5 lines: more than 4 newlines OR over ~300 chars
    // (catches both multi-line prompts and single long prompts that visually wrap).
    private var queryTextNeedsTruncation: Bool {
        let m = group.query.message
        if m.filter({ $0 == "\n" }).count > 4 { return true }
        return m.count > 300
    }

    private func copyQueryToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(group.query.message, forType: .string)
    }

    var body: some View {
        disclosureBody
    }

    private var disclosureBody: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isResponseExpanded },
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
            if group.kind == .meta {
                metaLabel
            } else {
                queryLabel
            }
        }
    }

    private var queryLabel: some View {
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
                Image(systemName: isResponseExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // NSTextView wrapper: drag inside selects text; a click without
            // drag falls through to onTap → toggleResponseExpanded.
            SelectableQueryText(
                attributed: highlightedString(group.query.message, query: model.trimmedSearchText),
                maxLines: queryTextNeedsTruncation && !isQueryTextExpanded ? 5 : 0,
                onTap: { toggleResponseExpanded() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if queryTextNeedsTruncation {
                Button {
                    let wasExpanded = isQueryTextExpanded
                    isQueryTextExpanded.toggle()
                    markClicked()
                    // Collapsing shrinks the ScrollView contentSize and can
                    // leave the current group out of viewport. Re-anchor it.
                    if wasExpanded {
                        model.requestScroll(toGroup: group.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isQueryTextExpanded ? "chevron.up" : "chevron.down")
                        Text(isQueryTextExpanded ? "Show less" : "Show more")
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .id(group.query.id)
        .background(queryBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(queryBorderColor, lineWidth: queryBorderWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            toggleResponseExpanded()
        }
        .contextMenu {
            Button("Copy Query") {
                copyQueryToPasteboard()
            }
        }
    }

    private var queryBackgroundColor: Color {
        if group.id == model.activeSearchGroupID {
            return Color.yellow.opacity(0.16)
        }
        if isLastClicked {
            return Color.accentColor.opacity(0.32)
        }
        return Color.accentColor.opacity(0.10)
    }

    private var queryBorderColor: Color {
        if group.id == model.activeSearchGroupID {
            return Color.accentColor
        }
        if isLastClicked {
            return Color.accentColor.opacity(0.75)
        }
        return Color(nsColor: .separatorColor)
    }

    private var queryBorderWidth: CGFloat {
        if group.id == model.activeSearchGroupID { return 1 }
        if isLastClicked { return 1 }
        return 0.5
    }

    private var metaLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(group.query.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let timestamp = group.query.timestamp {
                Text(timestamp, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .id(group.query.id)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }
}

// NSTextView-backed selectable label. Renders an AttributedString, supports
// drag-to-select (native NSTextView behaviour) AND fires `onTap` for a click
// that did not produce a selection — which SwiftUI's `.textSelection(.enabled)`
// + `.onTapGesture` combo cannot do because the Text view swallows the click.
struct SelectableQueryText: NSViewRepresentable {
    let attributed: AttributedString
    let maxLines: Int    // 0 = unlimited
    let onTap: () -> Void

    final class Coordinator {
        var onTap: () -> Void = {}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TappableTextView {
        let tv = TappableTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        if let tc = tv.textContainer {
            tc.lineFragmentPadding = 0
            tc.widthTracksTextView = true
        }
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.coordinator = context.coordinator
        tv.font = NSFont.preferredFont(forTextStyle: .body)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        return tv
    }

    func updateNSView(_ tv: TappableTextView, context: Context) {
        context.coordinator.onTap = onTap

        let base: NSAttributedString
        if let conv = try? NSAttributedString(attributed, including: \.appKit) {
            base = conv
        } else {
            base = NSAttributedString(string: String(attributed.characters))
        }
        let m = NSMutableAttributedString(attributedString: base)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: full) { val, range, _ in
            if val == nil {
                m.addAttribute(.font, value: NSFont.preferredFont(forTextStyle: .body), range: range)
            }
        }
        m.enumerateAttribute(.foregroundColor, in: full) { val, range, _ in
            if val == nil {
                m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 4
        m.addAttribute(.paragraphStyle, value: ps, range: full)
        tv.textStorage?.setAttributedString(m)
        if let tc = tv.textContainer {
            tc.maximumNumberOfLines = maxLines
            tc.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        }
        tv.invalidateIntrinsicContentSize()
    }
}

final class TappableTextView: NSTextView {
    weak var coordinator: SelectableQueryText.Coordinator?

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    // NSTextView.mouseDown runs a modal tracking loop until the mouse is released.
    // When it returns, we can compare selection state to decide tap vs drag-select.
    override func mouseDown(with event: NSEvent) {
        let preLen = selectedRange().length
        super.mouseDown(with: event)
        let postLen = selectedRange().length
        if postLen == 0 && preLen == 0 {
            coordinator?.onTap()
        }
    }
}

struct MessageView: View {
    let item: CleanMessage
    let searchText: String
    let isFocused: Bool

    @State private var isPreviewing: Bool = true

    private var canPreview: Bool {
        item.speaker != "You"
    }

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
                Spacer()
                if canPreview {
                    Button {
                        isPreviewing.toggle()
                    } label: {
                        Image(systemName: isPreviewing ? "doc.plaintext" : "doc.richtext")
                    }
                    .buttonStyle(.borderless)
                    .help(isPreviewing ? "Show raw text" : "Render markdown")
                }
            }
            if isPreviewing {
                MarkdownRenderedView(text: item.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(highlightedString(item.message, query: searchText))
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

private struct MdListItem {
    let text: String
    let checked: Bool?
    let children: [MdList]
}

private struct MdList {
    let ordered: Bool
    let items: [MdListItem]
}

private enum MdAlignment {
    case leading, center, trailing
}

private struct MdTable {
    let headers: [String]
    let alignments: [MdAlignment]
    let rows: [[String]]
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case list(MdList)
    case blockquote(String)
    case horizontalRule
    case table(MdTable)
}

private struct ListLineInfo {
    let indent: Int
    let ordered: Bool
    let checked: Bool?
    let content: String
}

private func parseListLine(_ raw: String) -> ListLineInfo? {
    var indent = 0
    for ch in raw {
        if ch == " " { indent += 1 }
        else if ch == "\t" { indent += 4 }
        else { break }
    }
    let body = String(raw.dropFirst(raw.prefix { $0 == " " || $0 == "\t" }.count))
    guard !body.isEmpty else { return nil }

    var ordered = false
    var contentStart: String.Index?

    if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
        contentStart = body.index(body.startIndex, offsetBy: 2)
    } else if let dot = body.firstIndex(of: "."),
              dot > body.startIndex,
              body[..<dot].allSatisfy({ $0.isNumber }) {
        let after = body.index(after: dot)
        if after < body.endIndex, body[after] == " " {
            ordered = true
            contentStart = body.index(after: after)
        }
    }

    guard let cs = contentStart else { return nil }
    var content = String(body[cs..<body.endIndex])
    var checked: Bool? = nil
    if content.hasPrefix("[ ] ") {
        checked = false
        content = String(content.dropFirst(4))
    } else if content.lowercased().hasPrefix("[x] ") {
        checked = true
        content = String(content.dropFirst(4))
    } else if content == "[ ]" {
        checked = false
        content = ""
    } else if content.lowercased() == "[x]" {
        checked = true
        content = ""
    }

    return ListLineInfo(indent: indent, ordered: ordered, checked: checked, content: content)
}

private func buildNestedList(_ items: [ListLineInfo], start: inout Int) -> MdList? {
    guard start < items.count else { return nil }
    let baseIndent = items[start].indent
    let ordered = items[start].ordered
    var built: [MdListItem] = []

    while start < items.count, items[start].indent == baseIndent {
        let cur = items[start]
        start += 1
        var children: [MdList] = []
        while start < items.count, items[start].indent > baseIndent {
            if let child = buildNestedList(items, start: &start) {
                children.append(child)
            } else {
                break
            }
        }
        built.append(MdListItem(text: cur.text(), checked: cur.checked, children: children))
    }
    return MdList(ordered: ordered, items: built)
}

extension ListLineInfo {
    func text() -> String { content }
}

private func splitTableRow(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

private func tableAlignment(_ cell: String) -> MdAlignment? {
    let t = cell.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    let leading = t.hasPrefix(":")
    let trailing = t.hasSuffix(":")
    var middle = t
    if leading { middle.removeFirst() }
    if trailing && !middle.isEmpty { middle.removeLast() }
    guard !middle.isEmpty, middle.allSatisfy({ $0 == "-" }) else { return nil }
    if leading && trailing { return .center }
    if trailing { return .trailing }
    return .leading
}

private func tableSeparatorAlignments(_ cells: [String]) -> [MdAlignment]? {
    guard !cells.isEmpty else { return nil }
    var aligns: [MdAlignment] = []
    for c in cells {
        guard let a = tableAlignment(c) else { return nil }
        aligns.append(a)
    }
    return aligns
}

private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    let lines = text.components(separatedBy: "\n")
    var index = 0

    func flushParagraph(_ buffer: inout [String]) {
        guard !buffer.isEmpty else { return }
        let joined = buffer.joined(separator: "\n")
        if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
            blocks.append(.paragraph(joined))
        }
        buffer.removeAll()
    }

    var paragraphBuffer: [String] = []

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            flushParagraph(&paragraphBuffer)
            index += 1
            continue
        }

        if trimmed.hasPrefix("```") {
            flushParagraph(&paragraphBuffer)
            let fenceLine = trimmed
            let lang = String(fenceLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            index += 1
            var codeLines: [String] = []
            while index < lines.count {
                let l = lines[index]
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    index += 1
                    break
                }
                codeLines.append(l)
                index += 1
            }
            blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
            continue
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flushParagraph(&paragraphBuffer)
            blocks.append(.horizontalRule)
            index += 1
            continue
        }

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }
            let level = hashes.count
            if level <= 6, trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                flushParagraph(&paragraphBuffer)
                let content = String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                index += 1
                continue
            }
        }

        if trimmed.hasPrefix("> ") || trimmed == ">" {
            flushParagraph(&paragraphBuffer)
            var quoteLines: [String] = []
            while index < lines.count {
                let t = lines[index].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("> ") {
                    quoteLines.append(String(t.dropFirst(2)))
                } else if t == ">" {
                    quoteLines.append("")
                } else {
                    break
                }
                index += 1
            }
            blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
            continue
        }

        if let _ = parseListLine(line) {
            flushParagraph(&paragraphBuffer)
            var listLines: [ListLineInfo] = []
            while index < lines.count, let info = parseListLine(lines[index]) {
                listLines.append(info)
                index += 1
            }
            var cursor = 0
            if let list = buildNestedList(listLines, start: &cursor) {
                blocks.append(.list(list))
            }
            continue
        }

        if trimmed.contains("|"), index + 1 < lines.count {
            let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if nextTrimmed.contains("|") || nextTrimmed.contains("-") {
                let headerCells = splitTableRow(trimmed)
                let sepCells = splitTableRow(nextTrimmed)
                if headerCells.count >= 1,
                   sepCells.count == headerCells.count,
                   let aligns = tableSeparatorAlignments(sepCells) {
                    flushParagraph(&paragraphBuffer)
                    index += 2
                    var rows: [[String]] = []
                    while index < lines.count {
                        let t = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty, t.contains("|") else { break }
                        let cells = splitTableRow(t)
                        var padded = cells
                        while padded.count < headerCells.count { padded.append("") }
                        if padded.count > headerCells.count {
                            padded = Array(padded.prefix(headerCells.count))
                        }
                        rows.append(padded)
                        index += 1
                    }
                    blocks.append(.table(MdTable(headers: headerCells, alignments: aligns, rows: rows)))
                    continue
                }
            }
        }

        paragraphBuffer.append(line)
        index += 1
    }

    flushParagraph(&paragraphBuffer)
    return blocks
}

private func inlineAttributed(_ text: String) -> AttributedString {
    if let attr = try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    ) {
        return attr
    }
    return AttributedString(text)
}

struct MarkdownRenderedView: View {
    let text: String

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(headingFont(level: level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
        case .list(let list):
            listView(list, depth: 0)
        case .table(let table):
            tableView(table)
        case .blockquote(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 3)
                Text(inlineAttributed(text))
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .horizontalRule:
            Divider()
        }
    }

    private func listView(_ list: MdList, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { idx, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            marker(for: item, index: idx, ordered: list.ordered)
                            Text(inlineAttributed(item.text))
                                .font(.body)
                                .textSelection(.enabled)
                                .strikethrough(item.checked == true, color: .secondary)
                                .foregroundStyle(item.checked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !item.children.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                                    listView(child, depth: depth + 1)
                                }
                            }
                            .padding(.leading, 20)
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func marker(for item: MdListItem, index: Int, ordered: Bool) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
        } else if ordered {
            Text("\(index + 1).")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("•").font(.body).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tableView(_ table: MdTable) -> some View {
        let columns = table.headers.count
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { i in
                        let text = i < table.headers.count ? table.headers[i] : ""
                        let align = i < table.alignments.count ? table.alignments[i] : .leading
                        Text(inlineAttributed(text))
                            .font(.body.bold())
                            .textSelection(.enabled)
                            .multilineTextAlignment(textAlignment(align))
                            .gridColumnAlignment(horizontalAlignment(align))
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { i in
                            let text = i < row.count ? row[i] : ""
                            let align = i < table.alignments.count ? table.alignments[i] : .leading
                            Text(inlineAttributed(text))
                                .font(.body)
                                .textSelection(.enabled)
                                .multilineTextAlignment(textAlignment(align))
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func horizontalAlignment(_ a: MdAlignment) -> HorizontalAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ a: MdAlignment) -> TextAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .body.bold()
        }
    }
}

@main
struct AgentLogApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("AgentLog", id: "main") {
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
                .keyboardShortcut("f", modifiers: [.command])
            }
        }

        MenuBarExtra("AgentLog", systemImage: "magnifyingglass.circle") {
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
