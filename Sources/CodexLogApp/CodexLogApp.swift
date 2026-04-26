import AppKit
import CSQLite
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSummary: Identifiable, Hashable {
    var id: String { cwd }
    let cwd: String
    let sessionCount: Int
    let updatedAt: Date

    var displayName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct CodexSession: Identifiable, Hashable {
    let id: String
    let cwd: String
    let title: String
    let rolloutPath: String
    let updatedAt: Date
    let model: String
    let gitBranch: String
}

struct CleanMessage: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date?
    let speaker: String
    let message: String
}

struct QueryGroup: Identifiable, Hashable {
    let id: UUID
    let query: CleanMessage
    let responses: [CleanMessage]

    var allMessages: [CleanMessage] {
        [query] + responses
    }

    var responseCount: Int {
        responses.count
    }
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
                    updatedAt: dateFromUnix(stmt, 2)
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
                    id: columnText(stmt, 0),
                    cwd: columnText(stmt, 1),
                    title: columnText(stmt, 2),
                    rolloutPath: columnText(stmt, 3),
                    updatedAt: dateFromUnix(stmt, 4),
                    model: columnText(stmt, 5),
                    gitBranch: columnText(stmt, 6)
                )
            }
        }
    }

    func messages(for session: CodexSession) throws -> [CleanMessage] {
        let url = URL(fileURLWithPath: NSString(string: session.rolloutPath).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexStoreError.rolloutMissing(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return text.split(separator: "\n").compactMap { line in
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
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            if db != nil { sqlite3_close(db) }
            throw CodexStoreError.databaseOpenFailed(message)
        }
        defer { sqlite3_close(db) }
        return try body(db)
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

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectSummary] = []
    @Published var sessions: [CodexSession] = []
    @Published var messages: [CleanMessage] = []
    @Published var selectedProject: ProjectSummary?
    @Published var selectedSession: CodexSession?
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var expandedQueryIDs: Set<UUID> = []

    private let store = CodexStore()

    func load() {
        do {
            projects = try store.projects()
            selectedProject = projects.first
            if let selectedProject {
                loadSessions(for: selectedProject)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSessions(for project: ProjectSummary) {
        do {
            selectedProject = project
            sessions = try store.sessions(cwd: project.cwd)
            selectedSession = sessions.first
            if let selectedSession {
                loadMessages(for: selectedSession)
            } else {
                messages = []
                expandedQueryIDs = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMessages(for session: CodexSession) {
        do {
            selectedSession = session
            messages = try store.messages(for: session)
            expandedQueryIDs = Set(queryGroups.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var queryGroups: [QueryGroup] {
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
                currentQuery = CleanMessage(timestamp: message.timestamp, speaker: "Session", message: "Session messages")
                currentResponses = [message]
            } else {
                currentResponses.append(message)
            }
        }
        flush()
        return groups
    }

    var filteredQueryGroups: [QueryGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return queryGroups
        }
        return queryGroups.filter { group in
            group.allMessages.contains { item in
                item.message.localizedCaseInsensitiveContains(trimmed)
                    || item.speaker.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    func expandAllQueries() {
        expandedQueryIDs = Set(queryGroups.map(\.id))
    }

    func collapseAllQueries() {
        expandedQueryIDs = []
    }

    func openSelectedProject() {
        guard let selectedProject else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: selectedProject.cwd))
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
        panel.message = "Export the clean Codex conversation as Markdown."
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
            "# \(session.title.isEmpty ? session.id : session.title)",
            "",
            "- id: \(session.id)",
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
        let rawTitle = session.title.isEmpty ? session.id : session.title
        let safeTitle = rawTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(String(session.id.prefix(8)))-\(safeTitle).md"
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

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
        .alert("Codex CLI Log", isPresented: Binding(
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
            Button {
                model.load()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
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
                Text(session.title.isEmpty ? session.id : session.title)
                    .font(.headline)
                    .lineLimit(3)
                HStack(spacing: 10) {
                    Text(shortID(session.id))
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

    private func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.filteredQueryGroups.isEmpty {
                ContentUnavailableView("No Queries", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.filteredQueryGroups) { group in
                            QueryGroupView(group: group, model: model)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search messages")
        .navigationTitle("Conversation")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.selectedSession?.title ?? "Select a session")
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)
            if let session = model.selectedSession {
                HStack(spacing: 12) {
                    Text(String(session.id.prefix(8)))
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
                    model.openSelectedProject()
                } label: {
                    Label("Open Project", systemImage: "folder")
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
                    Label("Expand", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                Button {
                    model.collapseAllQueries()
                } label: {
                    Label("Collapse", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    MessageView(item: item)
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
                Text(group.query.message)
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

struct MessageView: View {
    let item: CleanMessage

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
            Text(item.message)
                .textSelection(.enabled)
                .font(.body)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(item.speaker == "You" ? Color.accentColor.opacity(0.10) : Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

@main
struct CodexLogApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
