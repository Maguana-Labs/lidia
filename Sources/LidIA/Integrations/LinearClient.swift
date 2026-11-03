import Foundation
import os.log

/// Creates Linear issues through Linear's GraphQL API
/// (https://linear.app/developers/graphql) with a personal API key, which
/// goes in the `Authorization` header as is (no "Bearer"). Same shape as
/// `ClickUpClient`: every send checks `PrivacyGate` first, and only the
/// confirmation UI calls `createIssue`.
enum LinearClient {
    private static let logger = Logger(subsystem: "io.lidia.app", category: "LinearClient")
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    struct Team: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var key: String?
    }

    struct CreatedIssue: Equatable, Sendable {
        var id: String
        var identifier: String?
        var url: URL?
    }

    enum LinearError: LocalizedError, Equatable {
        case http(Int)
        case graphQL(String)
        case notCreated

        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): "Linear didn't accept the API key. Check it in Settings → Apps & Extensions → Linear."
            case .http(let code): "Linear returned HTTP \(code)."
            case .graphQL(let message): "Linear: \(message)"
            case .notCreated: "Linear didn't create the issue."
            }
        }
    }

    static let teamsQuery = "query Teams { teams { nodes { id name key } } }"
    static let createIssueMutation = """
        mutation IssueCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }
        """

    /// The request body for `issueCreate`. Internal for tests.
    static func createIssueBody(title: String, description: String, teamID: String) -> [String: Any] {
        [
            "query": createIssueMutation,
            "variables": ["input": ["title": title, "description": description, "teamId": teamID]],
        ]
    }

    /// The user's teams, for the settings picker. Reads only; sends no meeting content.
    static func teams(apiKey: String) async throws -> [Team] {
        let json = try await perform(["query": teamsQuery], apiKey: apiKey)
        let nodes = ((json["data"] as? [String: Any])?["teams"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { node in
            guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
            return Team(id: id, name: name, key: node["key"] as? String)
        }
    }

    /// Creates an issue. Call only after the user confirmed it.
    @discardableResult
    static func createIssue(title: String, description: String, teamID: String, apiKey: String) async throws -> CreatedIssue {
        try PrivacyGate.check(.linear)
        let json = try await perform(createIssueBody(title: title, description: description, teamID: teamID), apiKey: apiKey)
        return try parseCreatedIssue(json)
    }

    /// Reads an `issueCreate` response. Internal for tests.
    static func parseCreatedIssue(_ json: [String: Any]) throws -> CreatedIssue {
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw LinearError.graphQL(first["message"] as? String ?? "unknown error")
        }
        guard let result = (json["data"] as? [String: Any])?["issueCreate"] as? [String: Any],
              result["success"] as? Bool == true,
              let issue = result["issue"] as? [String: Any],
              let id = issue["id"] as? String else { throw LinearError.notCreated }
        logger.info("Linear: issue created")
        return CreatedIssue(id: id, identifier: issue["identifier"] as? String, url: (issue["url"] as? String).flatMap(URL.init(string:)))
    }

    private static func perform(_ body: [String: Any], apiKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            logger.error("Linear: HTTP \(http.statusCode)")
            throw LinearError.http(http.statusCode)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Linear can answer 200 with errors.
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first, json["data"] == nil {
            throw LinearError.graphQL(first["message"] as? String ?? "unknown error")
        }
        return json
    }
}
