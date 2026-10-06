import Foundation

struct Deadline {
    let id: String
    let label: String
    let timeLeft: String
    let percent: Double
    let due: Date?
}

struct Daily {
    let timeLeft: String
    let percent: Double
}

enum NotionError: Error {
    case noToken
    case notConfigured
    case http(Int)
    case malformed
}

enum Notion {
    private static func send(_ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let token = Settings.token ?? ProcessInfo.processInfo.environment["NOTION_TOKEN_DUMP"] else {
            throw NotionError.noToken
        }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!, timeoutInterval: 30)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { throw NotionError.http(code) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionError.malformed
        }
        return json
    }

    private static func parseDate(_ s: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return full.date(from: s) ?? plain.date(from: s) ?? dateOnly.date(from: s)
    }

    /// Maps a configured ID to the data sources to query, so it's only looked up once per ID.
    @MainActor private static var resolved: [String: [String]] = [:]

    /// A pasted database link gives a database ID, which can't be queried directly; use all of its data sources.
    /// An ID that isn't a database (404) is assumed to already be a data source ID.
    @MainActor private static func resolveDataSources(_ id: String) async throws -> [String] {
        if let cached = resolved[id] { return cached }
        let dataSources: [String]
        do {
            let json = try await send("databases/\(id)", body: nil)
            guard let list = json["data_sources"] as? [[String: Any]] else { throw NotionError.malformed }
            dataSources = list.compactMap { $0["id"] as? String }
        } catch NotionError.http(404) {
            dataSources = [id]
        }
        resolved[id] = dataSources
        return dataSources
    }

    static func fetchDeadlines() async throws -> [Deadline] {
        guard !Settings.dataSourceID.isEmpty else { throw NotionError.notConfigured }
        var out: [Deadline] = []
        for dataSourceID in try await resolveDataSources(Settings.dataSourceID) {
            out += try await fetchDeadlines(from: dataSourceID)
        }
        return out
    }

    private static func fetchDeadlines(from dataSourceID: String) async throws -> [Deadline] {
        var out: [Deadline] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "filter": ["and": [
                    ["property": "Done", "checkbox": ["equals": false]],
                    ["property": "Started", "formula": ["checkbox": ["equals": true]]],
                ]],
                "page_size": 100,
            ]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await send("data_sources/\(dataSourceID)/query", body: body)
            for row in json["results"] as? [[String: Any]] ?? [] {
                guard let id = row["id"] as? String,
                      let props = row["properties"] as? [String: Any] else { continue }
                let title = ((props["Label"] as? [String: Any])?["title"] as? [[String: Any]] ?? [])
                    .compactMap { $0["plain_text"] as? String }.joined()
                let formula = { (name: String) in (props[name] as? [String: Any])?["formula"] as? [String: Any] }
                let start = ((props["Due date"] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String
                out.append(Deadline(
                    id: id,
                    label: title.isEmpty ? "Untitled" : title,
                    timeLeft: formula("Time left")?["string"] as? String ?? "",
                    percent: (formula("Progress")?["number"] as? NSNumber)?.doubleValue ?? 0,
                    due: start.flatMap(parseDate)))
            }
            cursor = json["has_more"] as? Bool == true ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return out
    }

    static func fetchDaily() async throws -> Daily {
        let pageID = Settings.dailyPageID
        guard !pageID.isEmpty else { throw NotionError.notConfigured }
        let json = try await send("pages/\(pageID)", body: nil)
        guard let props = json["properties"] as? [String: Any] else { throw NotionError.malformed }
        let formula = { (name: String) in (props[name] as? [String: Any])?["formula"] as? [String: Any] }
        var left = formula("Time left")?["string"] as? String ?? ""
        if left.hasSuffix(" left") { left.removeLast(5) }
        return Daily(timeLeft: left,
                     percent: (formula("Progress")?["number"] as? NSNumber)?.doubleValue ?? 0)
    }
}
