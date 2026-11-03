import Foundation

/// The single hook every request to a cloud model passes through just before
/// it leaves this Mac (Anthropic, OpenAI-compatible cloud endpoints, and the
/// subscription CLIs).
///
/// It returns the messages unchanged today. PII masking (names, emails, phone
/// numbers replaced before sending and restored in the reply) is a planned
/// feature: see "Build order" in docs/strategy/2026-11-differentiation.md.
/// When it lands it goes here, so no client needs to change.
enum OutboundRedactor {
    static func prepare(_ messages: [LLMChatMessage], for destination: DataLocality) -> [LLMChatMessage] {
        guard destination == .cloud else { return messages }
        // TODO(PII masking): mask personal data here before it leaves the Mac.
        return messages
    }
}
