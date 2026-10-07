import Foundation
import os.log

private let logger = AppLogger(category: "AntigravityAgent")

/// AgentProvider implementation that wraps AntigravityProvider for the unified agent loop.
final class AntigravityAgentProvider: AgentProvider {

    let provider: AntigravityProvider

    var name: String { provider.name }
    var model: LLMModel { provider.model }
    var defaultMaxTokens: Int { 16_384 }

    init(provider: AntigravityProvider) {
        self.provider = provider
    }

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let geminiContents = convertMessages(messages)
        let geminiTools = convertTools(tools)

        let stream: AsyncThrowingStream<GeminiStreamEvent, Error>
        do {
            stream = try await provider.streamWithTools(
                contents: geminiContents,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                tools: geminiTools,
                thinkingLevel: thinkingLevel
            )
        } catch {
            throw provider.mapError(error)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedTextStart = false
                var hasToolCalls = false
                var emittedDone = false

                do {
                    for try await event in stream {
                        switch event {
                        case .textDelta(let text):
                            if !emittedTextStart {
                                continuation.yield(.contentBlockStart(.text))
                                emittedTextStart = true
                            }
                            continuation.yield(.textDelta(text))

                        case .thinkingDelta(let text):
                            continuation.yield(.thinkingDelta(text))

                        case .functionCall(let name, let args, let thoughtSignature):
                            emittedTextStart = false
                            hasToolCalls = true

                            let id = UUID().uuidString
                            let metadata = thoughtSignature.map { ToolCallMetadata(thoughtSignature: $0) }
                            continuation.yield(.contentBlockStart(.toolUse(id: id, name: name)))
                            continuation.yield(.toolCallComplete(id: id, name: name, args: args, metadata: metadata))

                        case .usage(let u):
                            continuation.yield(.usage(u))

                        case .finishReason(let reason):
                            let mapped: AgentStopReason
                            if hasToolCalls {
                                mapped = .toolUse
                            } else {
                                mapped = switch reason {
                                case "max_tokens": .maxTokens
                                default: .endTurn
                                }
                            }
                            if !emittedDone {
                                emittedDone = true
                                continuation.yield(.done(stopReason: mapped))
                            }

                        case .done:
                            if !emittedDone {
                                emittedDone = true
                                continuation.yield(.done(stopReason: hasToolCalls ? .toolUse : .endTurn))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.provider.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Message Conversion

    /// Whether the current model is a Claude model (requires `id` on functionCall/functionResponse).
    private var isClaude: Bool { model.id.lowercased().contains("claude") }

    private func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        // [IMG-3] Vision-capability gate (assembly layer): a text-only
        // model gets text placeholders instead of raw image bytes — same
        // rule the OpenAI path has always applied.
        let messages = AgentMessage.gatedForVisionCapability(
            messages,
            supportsImageInput: model.capabilities.supportedModalities.contains(.imageInput)
        )
        var toolNameMap: [String: String] = [:]
        for msg in messages {
            for part in msg.parts {
                if case .toolUse(let id, let name, _) = part {
                    toolNameMap[id] = name
                }
            }
        }

        let requiresSig = model.id.lowercased().contains("gemini-3")
        var unsignedToolCallIds: Set<String> = []
        if requiresSig {
            for msg in messages {
                for part in msg.parts {
                    if case .toolUse(let id, _, _) = part {
                        if toolCallMetadataMap[id]?.thoughtSignature == nil {
                            unsignedToolCallIds.insert(id)
                        }
                    }
                }
            }
            if !unsignedToolCallIds.isEmpty {
                logger.info("[AntigravityAgent] Converting \(unsignedToolCallIds.count) unsigned tool call(s) to text")
            }
        }

        return messages.map { msg in
            let role = msg.role == .user ? "user" : "model"
            var parts: [[String: Any]] = []

            for part in msg.parts {
                switch part {
                case .text(let text):
                    parts.append(GeminiWireFormat.textPart(text))

                case .toolUse(let id, let name, let input):
                    if unsignedToolCallIds.contains(id) {
                        let argsDesc = (try? JSONSerialization.data(withJSONObject: input))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        parts.append(["text": "[Called \(name) with: \(argsDesc)]"])
                    } else {
                        let sig = toolCallMetadataMap[id]?.thoughtSignature
                        var fcPart = GeminiConversation.functionCallPart(
                            name: name, args: input, thoughtSignature: sig
                        )
                        // Claude models require an `id` field on functionCall parts.
                        if isClaude, var fc = fcPart["functionCall"] as? [String: Any] {
                            fc["id"] = "\(name)-\(id)"
                            fcPart["functionCall"] = fc
                        }
                        parts.append(fcPart)
                    }

                case .toolResult(let id, let name, let content, _, let imageData, _, _, _):
                    let resolvedName = (!name.isEmpty ? name : toolNameMap[id]) ?? "unknown"
                    if unsignedToolCallIds.contains(id) {
                        let truncated = content.count > 500 ? String(content.prefix(500)) + "..." : content
                        parts.append(["text": "[Result of \(resolvedName): \(truncated)]"])
                        // Normalized through the unified prep (sniffed
                        // label, caps) — same rule as the Gemini exit.
                        if let data = imageData,
                           let prepared = ImagePayloadPrep.preparedForContext(data, passthroughFormats: ImagePayloadPrep.geminiPassthroughFormats) {
                            parts.append(["inlineData": ["mimeType": prepared.mimeType, "data": prepared.data.base64EncodedString()]])
                        }
                    } else {
                        var frPart = GeminiConversation.functionResponsePart(
                            name: resolvedName, response: GeminiWireFormat.functionResponseResult(content)
                        )
                        // Claude models require an `id` field on functionResponse parts.
                        if isClaude, var fr = frPart["functionResponse"] as? [String: Any] {
                            fr["id"] = "\(resolvedName)-\(id)"
                            frPart["functionResponse"] = fr
                        }
                        parts.append(frPart)
                        if let data = imageData,
                           let prepared = ImagePayloadPrep.preparedForContext(data, passthroughFormats: ImagePayloadPrep.geminiPassthroughFormats) {
                            parts.append(["inlineData": ["mimeType": prepared.mimeType, "data": prepared.data.base64EncodedString()]])
                        }
                    }

                case .imageData(let data, _, _):
                    // [IMG-1/IMG-3] Normalize through the unified prep
                    // instead of forwarding the recorded mime + raw bytes.
                    if let prepared = ImagePayloadPrep.preparedForContext(data, passthroughFormats: ImagePayloadPrep.geminiPassthroughFormats) {
                        parts.append(["inlineData": ["mimeType": prepared.mimeType, "data": prepared.data.base64EncodedString()]])
                    } else {
                        parts.append(GeminiWireFormat.textPart("[image omitted: unsupported or unreadable image format]"))
                    }
                }
            }

            if parts.isEmpty {
                parts.append(["text": "(empty)"])
            }

            return ["role": role, "parts": parts]
        }
    }

    // MARK: - Tool Conversion

    private func convertTools(_ tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            var properties: [String: [String: Any]] = [:]
            for (name, param) in tool.parameters {
                var prop: [String: Any] = [
                    "type": param.type.geminiType,
                    "description": param.description,
                ]
                if let enumValues = param.enumValues {
                    prop["description"] = "\(param.description) (values: \(enumValues.joined(separator: ", ")))"
                }
                properties[name] = prop
            }

            var params: [String: Any] = [
                "type": "OBJECT",
                "properties": properties,
                "required": tool.required,
            ]
            if let ordering = tool.propertyOrdering {
                params["propertyOrdering"] = ordering
            }
            return GeminiConversation.toolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: params
            )
        }
    }

    // MARK: - Thought Signature Tracking

    private var toolCallMetadataMap: [String: ToolCallMetadata] = [:]

    func recordToolCallMetadata(id: String, metadata: ToolCallMetadata?) {
        if let metadata {
            toolCallMetadataMap[id] = metadata
        }
    }

    func restoreToolCallMetadata(_ map: [String: ToolCallMetadata]) {
        toolCallMetadataMap.merge(map) { _, new in new }
    }
}
