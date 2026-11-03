import Foundation

// LidIA's native agent harness, built on the principles of the Pi harness
// (pi.dev): a short system prompt, a few well-specified tools, and no hidden
// context. Everything the model receives is recorded in an `AgentTranscript`
// and can be shown to the user ("View what was sent").

// MARK: - Messages

/// One message in an agent conversation, independent of the provider.
struct AgentMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// The result of one tool call.
        case tool
    }

    var role: Role
    var text: String
    /// Tool calls the assistant made in this message.
    var toolCalls: [AgentToolCall] = []
    /// For `.tool`: which call this answers, and the tool's name.
    var toolCallID: String?
    var toolName: String?
    /// For `.tool`: the call failed (bad arguments, unknown tool, handler error).
    var isError = false
    /// Provider-native assistant content to send back verbatim on the next
    /// request (Anthropic content blocks, including thinking blocks, which
    /// must be replayed unchanged). JSON text; nil for other providers.
    var nativeContentJSON: String?

    static func user(_ text: String) -> AgentMessage { AgentMessage(role: .user, text: text) }
    static func assistant(_ text: String) -> AgentMessage { AgentMessage(role: .assistant, text: text) }
}

/// A tool call as the model made it. Arguments stay JSON text so the
/// transcript shows exactly what the model produced.
struct AgentToolCall: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var argumentsJSON: String
}

/// How much thinking/effort to ask the model for. Low by default; never above medium.
enum AgentEffort: String, Codable, Sendable, CaseIterable {
    case low
    case medium
}

// MARK: - Tool schema

/// One argument of a tool. Tools take a flat object of these, which keeps the
/// schemas small enough for 4B models and Apple's 4K context.
struct AgentParameter: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case string
        case integer
        case boolean
        /// A calendar date as `YYYY-MM-DD`.
        case date
        /// One of a fixed set of strings.
        case oneOf([String])
    }

    let name: String
    let kind: Kind
    let description: String
    var required = false

    var jsonSchema: [String: Any] {
        var schema: [String: Any] = ["description": description]
        switch kind {
        case .string: schema["type"] = "string"
        case .integer: schema["type"] = "integer"
        case .boolean: schema["type"] = "boolean"
        case .date:
            schema["type"] = "string"
            schema["pattern"] = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
        case .oneOf(let values):
            schema["type"] = "string"
            schema["enum"] = values
        }
        return schema
    }

    /// `name?: type` for the compact tool list in JSON-action prompts.
    var compactSignature: String {
        let type: String
        switch kind {
        case .string: type = "string"
        case .integer: type = "integer"
        case .boolean: type = "boolean"
        case .date: type = "date YYYY-MM-DD"
        case .oneOf(let values): type = values.joined(separator: "|")
        }
        return "\(name)\(required ? "" : "?"): \(type)"
    }
}

/// What a tool is, as offered to the model.
struct AgentToolSpec: Sendable, Equatable {
    let name: String
    let description: String
    let parameters: [AgentParameter]

    /// JSON Schema of the arguments object.
    var jsonSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters { properties[parameter.name] = parameter.jsonSchema }
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        let required = parameters.filter(\.required).map(\.name)
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    var jsonSchemaText: String { AgentJSON.string(jsonSchema) }

    /// One line for the JSON-action prompt: `name(arg?: type, …) — description`.
    var compactLine: String {
        "- \(name)(\(parameters.map(\.compactSignature).joined(separator: ", "))): \(description)"
    }

    // MARK: Validation

    /// Checks `argumentsJSON` against the schema and returns typed values.
    /// Lenient where it's safe (numbers given as strings, `null` for optional
    /// arguments, unknown keys dropped); strict where a wrong value would
    /// mislead (missing required, wrong type, bad date, value not in the enum).
    func validate(_ argumentsJSON: String) -> Result<AgentArguments, AgentValidationError> {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let object: [String: Any]
        if trimmed.isEmpty {
            object = [:]
        } else {
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                return .failure(AgentValidationError(tool: name, problems: ["arguments are not valid JSON"]))
            }
            guard let dictionary = parsed as? [String: Any] else {
                return .failure(AgentValidationError(tool: name, problems: ["arguments must be a JSON object"]))
            }
            object = dictionary
        }
        return validate(object)
    }

    func validate(_ object: [String: Any]) -> Result<AgentArguments, AgentValidationError> {
        var values: [String: AgentValue] = [:]
        var problems: [String] = []
        for parameter in parameters {
            let raw = object[parameter.name]
            if raw == nil || raw is NSNull || (raw as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                if parameter.required { problems.append("\"\(parameter.name)\" is required") }
                continue
            }
            switch Self.coerce(raw!, to: parameter.kind) {
            case .value(let value): values[parameter.name] = value
            case .problem(let message): problems.append("\"\(parameter.name)\" \(message)")
            }
        }
        if !problems.isEmpty { return .failure(AgentValidationError(tool: name, problems: problems)) }
        return .success(AgentArguments(values: values))
    }

    private enum Coerced {
        case value(AgentValue)
        case problem(String)

        static func success(_ value: AgentValue) -> Coerced { .value(value) }
        static func failure(_ message: String) -> Coerced { .problem(message) }
    }

    private static func coerce(_ raw: Any, to kind: AgentParameter.Kind) -> Coerced {
        switch kind {
        case .string:
            if let string = raw as? String { return .success(.string(string)) }
            if let number = raw as? NSNumber, !(raw is Bool) { return .success(.string(number.stringValue)) }
            return .failure("must be a string")
        case .integer:
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return .success(.integer(number.intValue))
            }
            if let string = raw as? String, let int = Int(string.trimmingCharacters(in: .whitespaces)) { return .success(.integer(int)) }
            return .failure("must be an integer")
        case .boolean:
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return .success(.boolean(number.boolValue)) }
            if let string = raw as? String {
                switch string.lowercased() {
                case "true", "yes": return .success(.boolean(true))
                case "false", "no": return .success(.boolean(false))
                default: break
                }
            }
            return .failure("must be true or false")
        case .date:
            guard let string = (raw as? String)?.trimmingCharacters(in: .whitespaces) else { return .failure("must be a date YYYY-MM-DD") }
            guard AgentDates.parse(string) != nil else { return .failure("must be a date YYYY-MM-DD, got \"\(string)\"") }
            return .success(.string(String(string.prefix(10))))
        case .oneOf(let allowed):
            guard let string = (raw as? String)?.trimmingCharacters(in: .whitespaces) else {
                return .failure("must be one of \(allowed.joined(separator: ", "))")
            }
            let normalized = string.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            if let match = allowed.first(where: { $0.lowercased() == normalized || $0.lowercased() == string.lowercased() }) {
                return .success(.string(match))
            }
            return .failure("must be one of \(allowed.joined(separator: ", ")), got \"\(string)\"")
        }
    }
}

struct AgentValidationError: Error, Sendable, Equatable, LocalizedError {
    let tool: String
    let problems: [String]

    var errorDescription: String? { "Invalid arguments for \(tool): " + problems.joined(separator: "; ") }
}

enum AgentValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
}

/// Validated arguments of one call.
struct AgentArguments: Sendable, Equatable {
    var values: [String: AgentValue] = [:]

    func string(_ name: String) -> String? {
        switch values[name] {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .integer(let value): return String(value)
        case .boolean(let value): return String(value)
        case nil: return nil
        }
    }

    func integer(_ name: String) -> Int? {
        if case .integer(let value) = values[name] { return value }
        return nil
    }

    func bool(_ name: String) -> Bool? {
        if case .boolean(let value) = values[name] { return value }
        return nil
    }

    func date(_ name: String) -> Date? { string(name).flatMap(AgentDates.parse) }
}

// MARK: - Helpers

enum AgentJSON {
    /// Compact JSON with sorted keys (stable, so transcripts diff cleanly).
    static func string(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func array(_ text: String) -> [Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }
}

enum AgentDates {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let readableFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
        return formatter
    }()

    /// `YYYY-MM-DD` (anything after the first 10 characters is ignored).
    static func parse(_ text: String) -> Date? {
        let day = String(text.trimmingCharacters(in: .whitespaces).prefix(10))
        guard day.count == 10 else { return nil }
        return dayFormatter.date(from: day)
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func readable(_ date: Date) -> String { readableFormatter.string(from: date) }
}

extension String {
    /// At most `limit` characters, marking the cut.
    func agentTruncated(_ limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(max(0, limit - 1))) + "…"
    }
}
