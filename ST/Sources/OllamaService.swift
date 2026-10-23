import Foundation

public struct OllamaModel: Codable {
    public let name: String
    public let modifiedAt: String?
    public let size: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
    }
}

public struct OllamaTagsResponse: Codable {
    public let models: [OllamaModel]
}

public struct OllamaStreamChunk: Codable {
    public let model: String?
    public let createdAt: String?
    public let response: String?
    public let done: Bool?
    public let totalDuration: Int64?
    public let evalCount: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case response
        case done
        case totalDuration = "total_duration"
        case evalCount = "eval_count"
    }
}

public class OllamaService: NSObject, URLSessionDataDelegate {
    public static let shared = OllamaService()

    public var host: String = "http://localhost:11434"
    public var modelName: String = "gemma4:e4b"

    private var activeSession: URLSession?
    private var currentTask: URLSessionDataTask?
    private var buffer = Data()

    private var onTokenCallback: ((String) -> Void)?
    private var onCompleteCallback: ((Result<String, Error>) -> Void)?
    private var accumulatedText = ""

    private override init() {
        super.init()
    }

    public func checkHealth(completion: @escaping (Bool, [String]) -> Void) {
        guard let url = URL(string: "\(host)/api/tags") else {
            completion(false, [])
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion(false, []) }
                return
            }

            do {
                let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                let names = tags.models.map { $0.name }
                DispatchQueue.main.async { completion(true, names) }
            } catch {
                DispatchQueue.main.async { completion(true, []) }
            }
        }.resume()
    }

    public func cancelCurrentTranslation() {
        currentTask?.cancel()
        currentTask = nil
        onTokenCallback = nil
        onCompleteCallback = nil
        accumulatedText = ""
        buffer.removeAll()
    }

    public func translateStream(
        text: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        cancelCurrentTranslation()

        guard let url = URL(string: "\(host)/api/generate") else {
            onComplete(.failure(NSError(domain: "STError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL"])))
            return
        }

        self.onTokenCallback = onToken
        self.onCompleteCallback = onComplete
        self.accumulatedText = ""
        self.buffer.removeAll()

        let systemPrompt = "You are a professional English-to-Chinese translator. Translate the user input into fluent, natural Simplified Chinese. Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."

        let payload: [String: Any] = [
            "model": modelName,
            "system": systemPrompt,
            "prompt": text,
            "stream": true,
            "options": [
                "temperature": 0.2
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            onComplete(.failure(NSError(domain: "STError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 30.0

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.activeSession = session

        let task = session.dataTask(with: request)
        self.currentTask = task
        task.resume()
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        // Process line by line from NDJSON
        while let newlineRange = buffer.range(of: Data([0x0A])) { // '\n'
            let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            buffer.removeSubrange(0..<newlineRange.upperBound)

            if lineData.isEmpty { continue }

            if let chunk = try? JSONDecoder().decode(OllamaStreamChunk.self, from: lineData) {
                if let token = chunk.response, !token.isEmpty {
                    accumulatedText += token
                    onTokenCallback?(token)
                }

                if chunk.done == true {
                    let finalResult = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCompleteCallback?(.success(finalResult))
                    onCompleteCallback = nil
                    return
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code == NSURLErrorCancelled {
            // Cancelled intentionally, ignore
            return
        }

        if let error = error {
            onCompleteCallback?(.failure(error))
        } else if !accumulatedText.isEmpty {
            let finalResult = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            onCompleteCallback?(.success(finalResult))
        } else {
            let error = NSError(domain: "STError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Empty response from Ollama"])
            onCompleteCallback?(.failure(error))
        }
        onCompleteCallback = nil
    }
}
