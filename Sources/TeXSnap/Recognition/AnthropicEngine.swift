import Foundation

/// Calls the Claude Messages API directly (Swift has no official Anthropic SDK), streaming the reply.
struct AnthropicEngine: RecognitionEngine {
    let apiKey: String

    var displayName: String { "Anthropic API" }

    static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["TEXSNAP_API_BASE_URL"], let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.anthropic.com")!
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    private final class StreamState: @unchecked Sendable {
        var receivedText = false
    }

    func complete(_ request: EngineRequest, onText: @escaping @Sendable (String) -> Void) async throws -> EngineOutput {
        var useFallbacks = ModelCatalog.info(request.model).supportsFallbacks
        var attempt = 0
        while true {
            let state = StreamState()
            do {
                return try await stream(request, useFallbacks: useFallbacks, state: state, onText: onText)
            } catch let error as EngineError {
                // Older accounts or proxies may not accept the fallback beta; the request works without it.
                if case .http(400, let message, _) = error, useFallbacks, message.localizedCaseInsensitiveContains("fallback") {
                    useFallbacks = false
                    continue
                }
                // Retry transient failures, but never after part of the reply was shown.
                guard error.isRetryable, !state.receivedText, attempt < 2 else { throw error }
                attempt += 1
                let delay = min(error.retryAfter ?? Double(attempt * 2), 20)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func body(_ request: EngineRequest, useFallbacks: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": 32_000,
            "stream": true,
            "system": [["type": "text", "text": request.system, "cache_control": ["type": "ephemeral"]]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64",
                        "media_type": request.image.mediaType,
                        "data": request.image.data.base64EncodedString(),
                    ]],
                    ["type": "text", "text": request.prompt],
                ],
            ]],
        ]
        if ModelCatalog.info(request.model).supportsEffort {
            body["output_config"] = ["effort": request.effort]
        }
        if useFallbacks {
            body["fallbacks"] = "default"
        }
        return body
    }

    private func stream(_ request: EngineRequest, useFallbacks: Bool, state: StreamState,
                        onText: @escaping @Sendable (String) -> Void) async throws -> EngineOutput {
        var urlRequest = URLRequest(url: Self.baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if useFallbacks {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(request, useFallbacks: useFallbacks))

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.session.bytes(for: urlRequest)
        } catch {
            throw Self.translate(error)
        }
        guard let http = response as? HTTPURLResponse else { throw EngineError.network("No HTTP response.") }
        guard http.statusCode == 200 else {
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 65_536 { break }
                }
            } catch {}
            throw EngineError.http(status: http.statusCode, message: Self.errorMessage(data),
                                   retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init))
        }

        // Text blocks by content-block index. A server-side fallback can continue the reply in a later block.
        var blocks: [Int: String] = [:]
        var model = request.model
        var stopReason: String?
        var category: String?
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:"),
                      let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                      let type = event["type"] as? String
                else { continue }
                switch type {
                case "message_start":
                    if let served = (event["message"] as? [String: Any])?["model"] as? String { model = served }
                case "content_block_start":
                    if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any],
                       block["type"] as? String == "text" {
                        blocks[index] = block["text"] as? String ?? ""
                    }
                case "content_block_delta":
                    if let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                        blocks[index, default: ""] += text
                        state.receivedText = true
                        onText(Self.joined(blocks))
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any] {
                        stopReason = delta["stop_reason"] as? String ?? stopReason
                        category = (delta["stop_details"] as? [String: Any])?["category"] as? String ?? category
                    }
                case "error":
                    let error = event["error"] as? [String: Any]
                    throw EngineError.api(type: error?["type"] as? String ?? "api_error",
                                          message: error?["message"] as? String ?? "The API reported an error.")
                default:
                    break
                }
            }
        } catch let error as EngineError {
            throw error
        } catch {
            throw Self.translate(error)
        }

        if stopReason == "refusal" { throw EngineError.refusal(category: category) }
        let text = Self.joined(blocks)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.emptyResponse }
        return EngineOutput(text: text, model: model, truncated: stopReason == "max_tokens")
    }

    private static func joined(_ blocks: [Int: String]) -> String {
        blocks.keys.sorted().compactMap { blocks[$0] }.joined()
    }

    private static func translate(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : EngineError.network(urlError.localizedDescription)
        }
        return EngineError.network(error.localizedDescription)
    }

    /// Checks an API key with a free request (listing one model). Returns nil when the key works.
    static func checkKey(_ key: String) async -> String? {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url else { return "Invalid API address." }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "No response from the API." }
            if http.statusCode == 200 { return nil }
            return EngineError.http(status: http.statusCode, message: errorMessage(data), retryAfter: nil).localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no details" : String(text.prefix(300))
    }
}
