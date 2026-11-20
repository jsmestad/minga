import Darwin
import Foundation
import FoundationModels

private struct Message: Decodable {
    enum Role: String, Decodable { case system, user, assistant, tool }

    let role: Role
    let text: String
    let toolCallID: String?
    let toolCalls: [Call]
    let isError: Bool?

    private enum CodingKeys: String, CodingKey {
        case role, text
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case isError = "is_error"
    }
}

private struct Call: Codable, Sendable {
    let id: String
    let name: String
    let arguments: [String: JSONValue]
}

private struct ToolDeclaration: Decodable {
    let name: String
    let description: String
    let schema: [String: JSONValue]
}

private struct Inference: Decodable {
    let messages: [Message]
    let tools: [ToolDeclaration]
    let maxOutputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case messages, tools
        case maxOutputTokens = "max_output_tokens"
    }
}

private enum JSONValue: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Decimal), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .number(try value.decode(Decimal.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    var integer: Int? {
        guard case .number(let number) = self,
              let integer = Int(NSDecimalNumber(decimal: number).stringValue) else { return nil }
        return integer
    }
}

private struct Operation: Decodable {
    enum Kind: String, Decodable { case availability, infer }
    let op: Kind
}

private enum Availability: String, Encodable {
    case ready, unsupported, disabled
    case modelNotReady = "model_not_ready"
    case unsupportedLocale = "unsupported_locale"
    case probeFailed = "probe_failed"
}

private enum Frame: Encodable {
    case availability(Availability, context: Int? = nil)
    case delta(String)
    case stop
    case calls([Call])
    case error(String)

    private enum CodingKeys: String, CodingKey { case status, context, delta, finish, calls, error }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .availability(status, context):
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(context, forKey: .context)
        case .delta(let delta): try container.encode(delta, forKey: .delta)
        case .stop: try container.encode("stop", forKey: .finish)
        case .calls(let calls): try container.encode(calls, forKey: .calls)
        case .error(let error): try container.encode(error, forKey: .error)
        }
    }

    func emit() {
        do {
            var data = try JSONEncoder().encode(self)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            Darwin._exit(74) // Broken or unusable transport: no success by EOF.
        }
    }
}

private enum BridgeError: Error {
    case invalidRequest(String)
    case invalidSchema(String)
    case invalidArguments(String)
    case unavailable(Availability)
    case invalidTranscript
    case invalidToolGroup
    case unexpectedExecutorCall
    case contextBudget(input: Int, reserved: Int, limit: Int)
    case tokenCountUnavailable
    case outputLimit
    case rewrittenSnapshot
    case incompleteResponse
    case stopBeforeContinuation

    var message: String {
        switch self {
        case .invalidRequest(let reason): "Invalid Apple inference request: \(reason)"
        case .invalidSchema(let reason): "Unsupported Apple tool schema: \(reason)"
        case .invalidArguments(let name): "Invalid arguments for Apple tool \(name)"
        case .unavailable(let status): "Apple model unavailable: \(status.rawValue)"
        case .invalidTranscript: "Apple executor received an unexpected input transcript"
        case .invalidToolGroup: "Apple executor did not settle one complete new tool group"
        case .unexpectedExecutorCall: "Apple executor called out of order"
        case let .contextBudget(input, reserved, limit):
            "Apple context limit is \(limit) tokens; input uses \(input) with \(reserved) reserved for output"
        case .tokenCountUnavailable: "Apple did not provide a usable token count"
        case .outputLimit: "Apple output reached its token limit without a confirmed stop"
        case .rewrittenSnapshot: "Apple rewrote an already streamed text prefix"
        case .incompleteResponse: "Apple generation did not yield a complete response"
        case .stopBeforeContinuation: "Apple continued without a valid tool-group receipt"
        }
    }
}

@available(macOS 27.0, *)
private struct ArgumentSchema: Sendable {
    private enum Kind: String { case object, array, string, integer, number, boolean, null }

    private indirect enum Shape: Sendable {
        case object([String: ArgumentSchema], required: Set<String>)
        case array(ArgumentSchema, min: Int?, max: Int?, unique: Bool)
        case string(choices: [String]?, min: Int?, max: Int?)
        case integer(min: Int?, max: Int?)
        case number(min: Double?, max: Double?)
        case boolean, null
        case union([ArgumentSchema])
    }

    private let shape: Shape
    private let description: String?

    init(_ object: [String: JSONValue], at path: String) throws {
        let types: [Kind]
        switch object["type"] {
        case .string(let kind): types = try [Self.kind(kind, at: path)]
        case .array(let values):
            types = try values.map { value in
                guard case .string(let kind) = value else { throw Self.bad(path, "type") }
                return try Self.kind(kind, at: path)
            }
            guard !types.isEmpty, Set(types).count == types.count else { throw Self.bad(path, "type") }
        default: throw Self.bad(path, "type")
        }
        let allowed = types.reduce(into: Set(["type", "description"])) { $0.formUnion(Self.keys(for: $1)) }
        if let unsupported = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Self.bad(path, unsupported)
        }
        if let value = object["description"] {
            guard case .string(let text) = value else { throw Self.bad(path, "description") }
            description = text
        } else {
            description = nil
        }
        if types.count == 1, let type = types.first {
            shape = try Self.shape(type, in: object, at: path)
        } else {
            // An enum is a constraint over the whole value, not just the string branch.
            guard object["enum"] == nil else { throw Self.bad(path, "enum with a union type") }
            shape = .union(try types.map { .init(shape: try Self.shape($0, in: object, at: path), description: nil) })
        }
    }

    private init(shape: Shape, description: String?) {
        self.shape = shape
        self.description = description
    }

    var isObject: Bool {
        if case .object = shape { true } else { false }
    }

    private static func bad(_ path: String, _ keyword: String) -> BridgeError {
        .invalidSchema("\(path): \(keyword)")
    }

    private static func kind(_ raw: String, at path: String) throws -> Kind {
        guard let kind = Kind(rawValue: raw) else { throw bad(path, "type \(raw)") }
        return kind
    }

    private static func keys(for type: Kind) -> Set<String> {
        switch type {
        case .object: ["properties", "required", "additionalProperties"]
        case .array: ["items", "minItems", "maxItems", "uniqueItems"]
        case .string: ["enum", "minLength", "maxLength"]
        case .integer, .number: ["minimum", "maximum"]
        case .boolean, .null: []
        }
    }

    private static func shape(_ type: Kind, in object: [String: JSONValue], at path: String) throws -> Shape {
        switch type {
        case .object:
            // Minga declares named arguments even when it omits additionalProperties.
            // Apple has no open-dictionary schema; an explicitly open object is unsupported.
            guard object["additionalProperties"] == nil || object["additionalProperties"] == .bool(false) else {
                throw bad(path, "additionalProperties")
            }
            guard case .object(let properties) = object["properties"] else { throw bad(path, "properties") }
            let required = try strings(object["required"], at: path, key: "required") ?? []
            guard required.allSatisfy({ properties[$0] != nil }) else { throw bad(path, "required") }
            var fields: [String: ArgumentSchema] = [:]
            for (key, value) in properties {
                guard !key.isEmpty, case .object(let property) = value else { throw bad(path, "properties") }
                fields[key] = try ArgumentSchema(property, at: "\(path).\(key)")
            }
            return .object(fields, required: Set(required))
        case .array:
            guard case .object(let items) = object["items"] else { throw bad(path, "items") }
            let (min, max) = try intBounds(object, "minItems", "maxItems", at: path, nonnegative: true)
            let unique: Bool
            switch object["uniqueItems"] {
            case nil: unique = false
            case .bool(let value): unique = value
            default: throw bad(path, "uniqueItems")
            }
            return .array(try ArgumentSchema(items, at: "\(path)[]"), min: min, max: max, unique: unique)
        case .string:
            let choices = try strings(object["enum"], at: path, key: "enum")
            let (min, max) = try intBounds(object, "minLength", "maxLength", at: path, nonnegative: true)
            guard choices?.isEmpty != true else { throw bad(path, "enum") }
            return .string(choices: choices, min: min, max: max)
        case .integer:
            let (min, max) = try intBounds(object, "minimum", "maximum", at: path)
            return .integer(min: min, max: max)
        case .number:
            let min = try double(object["minimum"], at: path, key: "minimum")
            let max = try double(object["maximum"], at: path, key: "maximum")
            if let min, let max, min > max { throw bad(path, "minimum exceeds maximum") }
            return .number(min: min, max: max)
        case .boolean: return .boolean
        case .null: return .null
        }
    }

    private static func strings(_ value: JSONValue?, at path: String, key: String) throws -> [String]? {
        guard let value else { return nil }
        guard case .array(let elements) = value else { throw bad(path, key) }
        let strings = try elements.map { item in
            guard case .string(let string) = item else { throw bad(path, key) }
            return string
        }
        guard Set(strings).count == strings.count else { throw bad(path, key) }
        return strings
    }

    private static func double(_ value: JSONValue?, at path: String, key: String) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value else { throw bad(path, key) }
        let double = NSDecimalNumber(decimal: number).doubleValue
        guard double.isFinite, Decimal(string: String(double)) == number else { throw bad(path, key) }
        return double
    }

    private static func intBounds(
        _ object: [String: JSONValue], _ lower: String, _ upper: String, at path: String, nonnegative: Bool = false
    ) throws -> (Int?, Int?) {
        func bound(_ key: String) throws -> Int? {
            guard let value = object[key] else { return nil }
            guard let integer = value.integer, !nonnegative || integer >= 0 else { throw bad(path, key) }
            return integer
        }
        let min = try bound(lower)
        let max = try bound(upper)
        if let min, let max, min > max { throw bad(path, "\(lower) exceeds \(upper)") }
        return (min, max)
    }

    func generationSchema(prefix: String) throws -> GenerationSchema {
        var nextID = 0
        return try GenerationSchema(root: dynamicSchema(prefix: prefix, nextID: &nextID), dependencies: [])
    }

    private func dynamicSchema(prefix: String, nextID: inout Int) -> DynamicGenerationSchema {
        nextID += 1
        let name = "\(prefix)Arguments\(nextID)"
        switch shape {
        case let .object(fields, required):
            let properties = fields.sorted(by: { $0.key < $1.key }).map { key, schema in
                DynamicGenerationSchema.Property(
                    name: key, description: schema.guidance,
                    schema: schema.dynamicSchema(prefix: prefix, nextID: &nextID),
                    isOptional: !required.contains(key)
                )
            }
            return .init(name: name, description: description, properties: properties)
        case let .array(items, min, max, _):
            return .init(
                arrayOf: items.dynamicSchema(prefix: prefix, nextID: &nextID),
                minimumElements: min, maximumElements: max
            )
        case let .string(choices, _, _):
            if let choices { return .init(name: name, anyOf: choices) }
            return .init(type: String.self)
        case let .integer(min, max):
            var guides: [GenerationGuide<Int>] = []
            if let min { guides.append(.minimum(min)) }
            if let max { guides.append(.maximum(max)) }
            return .init(type: Int.self, guides: guides)
        case let .number(min, max):
            var guides: [GenerationGuide<Double>] = []
            if let min { guides.append(.minimum(min)) }
            if let max { guides.append(.maximum(max)) }
            return .init(type: Double.self, guides: guides)
        case .boolean: return .init(type: Bool.self)
        case .null: return .null
        case .union(let choices):
            return .init(name: name, anyOf: choices.map { $0.dynamicSchema(prefix: prefix, nextID: &nextID) })
        }
    }

    // Apple supplies no string-length or unique-items guide. Explain those rules in
    // the declaration and check them before accepting a callback or publishing a group.
    private var guidance: String? {
        var sentences = description.map { [$0] } ?? []
        switch shape {
        case let .string(_, min, max):
            if let min { sentences.append("String length must be at least \(min) Unicode scalars.") }
            if let max { sentences.append("String length must be at most \(max) Unicode scalars.") }
        case let .array(items, _, _, unique):
            if unique { sentences.append("Array items must be distinct.") }
            if let rule = items.guidance { sentences.append("For each array item: \(rule)") }
        case .union(let choices):
            sentences.append(contentsOf: choices.compactMap(\.guidance))
        default: break
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    func accepts(_ value: JSONValue) -> Bool {
        switch (shape, value) {
        case let (.object(fields, required), .object(values)):
            return required.allSatisfy { values[$0] != nil } && values.allSatisfy { key, value in
                fields[key]?.accepts(value) == true
            }
        case let (.array(items, min, max, unique), .array(values)):
            guard Self.within(values.count, min: min, max: max), values.allSatisfy(items.accepts) else { return false }
            return !unique || Set(values).count == values.count
        case let (.string(choices, min, max), .string(value)):
            return (choices?.contains { $0.utf8.elementsEqual(value.utf8) } ?? true)
                && Self.within(value.unicodeScalars.count, min: min, max: max)
        case let (.integer(min, max), number):
            return number.integer.map { Self.within($0, min: min, max: max) } ?? false
        case let (.number(min, max), .number(number)):
            let value = NSDecimalNumber(decimal: number).doubleValue
            return value.isFinite && Self.within(value, min: min, max: max)
        case (.boolean, .bool), (.null, .null): return true
        case let (.union(choices), value): return choices.contains { $0.accepts(value) }
        default: return false
        }
    }

    private static func within<T: Comparable>(_ value: T, min: T?, max: T?) -> Bool {
        (min.map { value >= $0 } ?? true) && (max.map { value <= $0 } ?? true)
    }
}

@available(macOS 27.0, *)
private struct ProposalTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    private let schema: ArgumentSchema
    private let marker: String

    init(declaration: ToolDeclaration, schemaPrefix: String, marker: String) throws {
        let schema = try ArgumentSchema(declaration.schema, at: declaration.name)
        guard schema.isObject else { throw BridgeError.invalidSchema("\(declaration.name): arguments must be an object") }
        do { parameters = try schema.generationSchema(prefix: schemaPrefix) }
        catch { throw BridgeError.invalidSchema("\(declaration.name): Apple rejected the projected schema") }
        self.schema = schema
        self.marker = marker
        name = declaration.name
        description = declaration.description
    }

    func arguments(_ content: GeneratedContent) throws -> [String: JSONValue] {
        guard content.isComplete, case .structure = content.kind,
              let value = try? JSONDecoder().decode([String: JSONValue].self, from: Data(content.jsonString.utf8)),
              schema.accepts(.object(value)) else { throw BridgeError.invalidArguments(name) }
        return value
    }

    func call(arguments: GeneratedContent) async throws -> String {
        try Task.checkCancellation()
        _ = try self.arguments(arguments)
        return marker
    }
}

@available(macOS 27.0, *)
private struct Projection: Sendable {
    let history: [Transcript.Entry]
    let historicalIDs: Set<String>
    let definitions: [Transcript.ToolDefinition]
    let userPrompt: String?
    let maxOutputTokens: Int

    init(_ inference: Inference, tools: [ProposalTool]) throws {
        guard inference.maxOutputTokens > 0 else { throw BridgeError.invalidRequest("max_output_tokens must be positive") }
        maxOutputTokens = inference.maxOutputTokens
        definitions = tools.map { Transcript.ToolDefinition(tool: $0) }
        guard let last = inference.messages.last, last.role == .user || last.role == .tool else {
            throw BridgeError.invalidRequest("expected a user prompt or settled tool results")
        }
        userPrompt = last.role == .user ? last.text : nil

        var entries: [Transcript.Entry] = []
        var instructions: [Transcript.Segment] = []
        var pending: [String: String] = [:]
        var known: Set<String> = []
        var atStart = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (index, message) in inference.messages.enumerated() {
            guard (message.role == .tool) == (message.isError != nil) else {
                throw BridgeError.invalidRequest("is_error must be a boolean on tool results only")
            }
            guard (message.role == .tool) == (message.toolCallID != nil),
                  message.role == .assistant || message.toolCalls.isEmpty,
                  pending.isEmpty || message.role == .tool else {
                throw BridgeError.invalidRequest("unsettled or misplaced tool call/result")
            }
            if message.role == .system {
                guard atStart else { throw BridgeError.invalidRequest("system messages must precede the conversation") }
                instructions.append(.text(.init(content: message.text)))
                continue
            }
            if atStart {
                if !instructions.isEmpty || !definitions.isEmpty {
                    entries.append(.instructions(.init(segments: instructions, toolDefinitions: definitions)))
                }
                atStart = false
            }
            if index == inference.messages.count - 1, message.role == .user { break }

            switch message.role {
            case .user:
                entries.append(.prompt(.init(segments: [.text(.init(content: message.text))])))
            case .assistant:
                if !message.text.isEmpty || message.toolCalls.isEmpty {
                    entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: message.text))])))
                }
                if !message.toolCalls.isEmpty {
                    let calls = try message.toolCalls.map { call in
                        guard !call.id.isEmpty, !call.name.isEmpty, known.insert(call.id).inserted else {
                            throw BridgeError.invalidRequest("missing or duplicate historical tool identity")
                        }
                        let json = try encoder.encode(call.arguments)
                        let arguments = try GeneratedContent(json: String(decoding: json, as: UTF8.self))
                        guard arguments.isComplete,
                              try JSONDecoder().decode([String: JSONValue].self, from: Data(arguments.jsonString.utf8)) == call.arguments else {
                            throw BridgeError.invalidRequest("historical tool arguments do not round-trip through Apple")
                        }
                        pending[call.id] = call.name
                        return Transcript.ToolCall(id: call.id, toolName: call.name, arguments: arguments)
                    }
                    entries.append(.toolCalls(.init(calls)))
                }
            case .tool:
                guard let id = message.toolCallID, let isError = message.isError,
                      let name = pending.removeValue(forKey: id) else {
                    throw BridgeError.invalidRequest("tool result does not match exactly one pending call")
                }
                // The ToolOutput has no native failure flag. Keep it in a typed
                // envelope so arbitrary result text cannot impersonate the status.
                let status = GeneratedContent(properties: ["is_error": isError])
                let segments: [Transcript.Segment] = [
                    .structure(.init(schemaName: "MingaToolStatus", content: status)),
                    .text(.init(content: message.text)),
                ]
                entries.append(.toolOutput(.init(id: id, toolName: name, segments: segments)))
            case .system: throw BridgeError.invalidTranscript
            }
        }
        guard pending.isEmpty else { throw BridgeError.invalidRequest("missing tool results") }
        history = entries
        historicalIDs = known
    }

    func request(_ request: LanguageModelExecutorGenerationRequest) throws -> LanguageModelExecutorGenerationRequest {
        let transcript = request.transcript
        // Verify the API appended exactly one prompt to the known history. Only drop
        // this entry on continuation, never a historical or actual empty user prompt.
        guard transcript.count == history.count + 1,
              transcript.dropLast().elementsEqual(history),
              request.enabledToolDefinitions == definitions,
              request.schema == nil, request.generationOptions.maximumResponseTokens == maxOutputTokens,
              case .prompt(let tail) = transcript.last,
              tail.responseFormat == nil, tail.metadata.isEmpty, tail.options == request.generationOptions,
              try text(in: tail.segments).utf8.elementsEqual((userPrompt ?? "").utf8) else {
            throw BridgeError.invalidTranscript
        }
        guard userPrompt == nil else { return request }
        var projected = request
        projected.transcript = Transcript(entries: history)
        return projected
    }
}

@available(macOS 27.0, *)
private func text(in segments: [Transcript.Segment]) throws -> String {
    var text = ""
    for segment in segments {
        guard case .text(let value) = segment else { throw BridgeError.invalidTranscript }
        text += value.content
    }
    return text
}

@available(macOS 27.0, *)
private struct ProposalReceipt: Sendable {
    let calls: [Call]
    let text: String
}

@available(macOS 27.0, *)
private actor Attempt {
    private enum Phase {
        case idle, running(Transcript), forwarded(Transcript), settled(ProposalReceipt), invalid
    }

    private var phase = Phase.idle
    private let projection: Projection
    private let tools: [String: ProposalTool]
    private let marker: String

    init(projection: Projection, tools: [ProposalTool], marker: String) {
        self.projection = projection
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.marker = marker
    }

    func begin(_ request: LanguageModelExecutorGenerationRequest) throws -> LanguageModelExecutorGenerationRequest {
        try Task.checkCancellation()
        switch phase {
        case .idle:
            phase = .invalid
            let projected = try projection.request(request)
            phase = .running(request.transcript)
            return projected
        case .forwarded(let prefix):
            phase = .invalid
            let receipt = try settle(request.transcript, after: prefix)
            try Task.checkCancellation()
            phase = .settled(receipt)
            throw BridgeError.stopBeforeContinuation
        case .running, .settled, .invalid:
            phase = .invalid
            throw BridgeError.unexpectedExecutorCall
        }
    }

    func upstreamReturned() throws {
        try Task.checkCancellation()
        guard case .running(let prefix) = phase else { throw BridgeError.unexpectedExecutorCall }
        phase = .forwarded(prefix)
    }

    func confirmResponse(_ response: LanguageModelSession.Response<String>, in transcript: Transcript) throws -> String {
        try Task.checkCancellation()
        guard case .forwarded(let prefix) = phase,
              transcript.prefix(prefix.count).elementsEqual(prefix),
              transcript.count == prefix.count + 1,
              case .response(let entry) = transcript.last, response.rawContent.isComplete,
              !response.content.isEmpty,
              try text(in: entry.segments).utf8.elementsEqual(response.content.utf8) else {
            throw BridgeError.incompleteResponse
        }
        return response.content
    }

    func receipt() throws -> ProposalReceipt {
        try Task.checkCancellation()
        guard case .settled(let receipt) = phase else { throw BridgeError.invalidToolGroup }
        return receipt
    }

    private func settle(_ transcript: Transcript, after prefix: Transcript) throws -> ProposalReceipt {
        guard transcript.prefix(prefix.count).elementsEqual(prefix) else { throw BridgeError.invalidToolGroup }
        var fresh = transcript.dropFirst(prefix.count)
        let response: String
        if case .response(let entry) = fresh.first {
            response = try text(in: entry.segments)
            fresh = fresh.dropFirst()
        } else {
            response = ""
        }
        guard case .toolCalls(let group) = fresh.first, !group.isEmpty,
              fresh.count == group.count + 1 else { throw BridgeError.invalidToolGroup }

        var receipts: [String: String] = [:]
        for entry in fresh.dropFirst() {
            guard case .toolOutput(let output) = entry, !output.id.isEmpty,
                  output.segments.count == 1, try text(in: output.segments) == marker,
                  receipts.updateValue(output.toolName, forKey: output.id) == nil else {
                throw BridgeError.invalidToolGroup
            }
        }
        let calls = try group.map { call in
            guard !call.id.isEmpty, !projection.historicalIDs.contains(call.id),
                  receipts.removeValue(forKey: call.id) == call.toolName,
                  let tool = tools[call.toolName] else { throw BridgeError.invalidToolGroup }
            return Call(id: call.id, name: call.toolName, arguments: try tool.arguments(call.arguments))
        }
        return .init(calls: calls, text: response)
    }
}

@available(macOS 27.0, *)
private struct OneInferenceModel: LanguageModel {
    let actual: SystemLanguageModel
    let attempt: Attempt
    var capabilities: LanguageModelCapabilities { actual.capabilities }
    var executorConfiguration: Executor.Configuration { .init() }

    struct Executor: LanguageModelExecutor {
        struct Configuration: Hashable, Sendable {}
        init(configuration: Configuration) {}

        func respond(
            to request: LanguageModelExecutorGenerationRequest, model: OneInferenceModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let request = try await model.attempt.begin(request)
            guard let reserve = request.generationOptions.maximumResponseTokens else { throw BridgeError.invalidTranscript }
            let limit = model.actual.contextSize
            let tokens = try await model.actual.tokenCount(for: request.transcript)
            guard tokens > 0, limit > 0 else { throw BridgeError.tokenCountUnavailable }
            guard reserve <= limit, tokens <= limit - reserve else {
                throw BridgeError.contextBudget(input: tokens, reserved: reserve, limit: limit)
            }
            try Task.checkCancellation()
            let status = AppleInference.status(of: model.actual)
            guard status == .ready else { throw BridgeError.unavailable(status) }
            let executor = SystemLanguageModel.Executor(configuration: model.actual.executorConfiguration)
            try await executor.respond(to: request, model: model.actual, streamingInto: channel)
            try await model.attempt.upstreamReturned()
        }
    }
}

private struct TextDeltas {
    private var previous = ""

    mutating func emit(upTo snapshot: String) throws {
        // Compare bytes, not Characters: a combining mark or ZWJ can extend the
        // last grapheme, and canonically equivalent characters can have different bytes.
        guard snapshot.utf8.starts(with: previous.utf8) else { throw BridgeError.rewrittenSnapshot }
        guard snapshot.utf8.count != previous.utf8.count else { return }
        try Task.checkCancellation()
        Frame.delta(String(decoding: snapshot.utf8.dropFirst(previous.utf8.count), as: UTF8.self)).emit()
        previous = snapshot
    }
}

private enum PortInput {
    static func firstFrame() -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(into: &buffer)
            guard count > 0 else { return nil }
            let bytes = buffer.prefix(count)
            if let newline = bytes.firstIndex(of: 10) {
                if bytes.dropFirst(newline + 1).contains(10) { Darwin._exit(130) }
                data.append(contentsOf: bytes[..<newline])
                return data
            }
            data.append(contentsOf: bytes)
        }
    }

    static func exitWhenCancelled() {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(into: &buffer)
            if count <= 0 || buffer.prefix(count).contains(10) { Darwin._exit(130) }
        }
    }

    private static func read(into buffer: inout [UInt8]) -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count >= 0 || errno != EINTR { return count }
        }
    }
}

@main
private struct AppleInference {
    static func main() async {
        guard let input = PortInput.firstFrame() else { return }
        // Stdin is the Port owner's lifeline. A separate blocking queue can retire
        // the process even while Foundation Models or a stdout pipe write is blocked.
        DispatchQueue.global(qos: .userInitiated).async {
            PortInput.exitWhenCancelled()
        }
        do {
            let operation = try JSONDecoder().decode(Operation.self, from: input)
            guard #available(macOS 27.0, *) else {
                switch operation.op {
                case .availability: Frame.availability(.unsupported).emit()
                case .infer: Frame.error(BridgeError.unavailable(.unsupported).message).emit()
                }
                return
            }
            let model = SystemLanguageModel.default
            let status = status(of: model)
            switch operation.op {
            case .availability:
                Frame.availability(status, context: status == .ready ? model.contextSize : nil).emit()
            case .infer:
                guard status == .ready else { throw BridgeError.unavailable(status) }
                let request = try JSONDecoder().decode(Inference.self, from: input)
                try await infer(request, with: model).emit()
            }
        } catch let error as BridgeError {
            Frame.error(error.message).emit()
        } catch is CancellationError {
            Frame.error("Apple inference cancelled").emit()
        } catch is DecodingError {
            Frame.error("Malformed Apple inference request").emit()
        } catch {
            Frame.error("Apple inference failed: \(error.localizedDescription)").emit()
        }
    }

    @available(macOS 27.0, *)
    fileprivate static func status(of model: SystemLanguageModel) -> Availability {
        switch model.availability {
        case .available:
            guard model.supportsLocale() else { return .unsupportedLocale }
            return model.contextSize > 0 ? .ready : .probeFailed
        case .unavailable(.deviceNotEligible): return .unsupported
        case .unavailable(.appleIntelligenceNotEnabled): return .disabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .probeFailed
        }
    }

    @available(macOS 27.0, *)
    private static func infer(_ inference: Inference, with model: SystemLanguageModel) async throws -> Frame {
        let marker = "MINGA_TOOL_CAPTURE_\(UUID().uuidString)"
        var names: Set<String> = []
        let tools = try inference.tools.enumerated().map { index, declaration in
            guard !declaration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  names.insert(declaration.name).inserted else {
                throw BridgeError.invalidRequest("missing or duplicate tool name")
            }
            return try ProposalTool(declaration: declaration, schemaPrefix: "Tool\(index + 1)", marker: marker)
        }
        let projection = try Projection(inference, tools: tools)
        let attempt = Attempt(projection: projection, tools: tools, marker: marker)
        let session = LanguageModelSession(
            model: OneInferenceModel(actual: model, attempt: attempt), tools: tools,
            transcript: Transcript(entries: projection.history)
        )
        let options = GenerationOptions(maximumResponseTokens: inference.maxOutputTokens)
        let stream = session.streamResponse(to: projection.userPrompt ?? "", options: options)
        var deltas = TextDeltas()
        var observedOutputTokens = 0
        do {
            for try await snapshot in stream {
                observedOutputTokens = max(observedOutputTokens, snapshot.usage.output.totalTokenCount)
                try deltas.emit(upTo: snapshot.content)
            }
            let response = try await stream.collect()
            let final = try await attempt.confirmResponse(response, in: session.transcript)
            let finalOutputTokens = response.usage.output.totalTokenCount
            guard finalOutputTokens > 0 else { throw BridgeError.tokenCountUnavailable }
            guard max(finalOutputTokens, observedOutputTokens) < inference.maxOutputTokens else {
                throw BridgeError.outputLimit
            }
            try deltas.emit(upTo: final)
            try Task.checkCancellation()
            return .stop
        } catch BridgeError.stopBeforeContinuation {
            let receipt = try await attempt.receipt()
            // Reentry proves that Apple handed off a complete executable group,
            // not that generation stopped naturally. No final Response is produced
            // here, and the partial/session counts need not include the whole group.
            // They can veto a known cap hit, but cannot certify below-cap usage.
            guard max(observedOutputTokens, session.usage.output.totalTokenCount) < inference.maxOutputTokens else {
                throw BridgeError.outputLimit
            }
            try deltas.emit(upTo: receipt.text)
            try Task.checkCancellation()
            return .calls(receipt.calls)
        } catch let error as LanguageModelSession.ToolCallError {
            if let underlying = error.underlyingError as? BridgeError { throw underlying }
            throw error
        }
    }
}
