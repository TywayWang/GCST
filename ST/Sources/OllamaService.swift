import Foundation

public struct OllamaModel: Codable {
    public let name: String
    public let modifiedAt: String?
    public let size: Int64?
    public let capabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case capabilities
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
    public var cachedModels: [String] = ["gemma4:e4b"]

    private var activeSession: URLSession?
    private var currentTask: URLSessionDataTask?
    private var buffer = Data()

    private var onTokenCallback: ((String) -> Void)?
    private var onCompleteCallback: ((Result<String, Error>) -> Void)?
    private var accumulatedText = ""

    private override init() {
        super.init()
        loadConfiguredModel()
        fetchModels(completion: nil)
    }

    private func loadConfiguredModel() {
        let configURL = URL(fileURLWithPath: "config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = json["model"] as? String, !m.isEmpty {
            self.modelName = m
        }
    }

    public func setModel(_ name: String) {
        self.modelName = name
    }

    public func fetchModels(completion: (([String]) -> Void)?) {
        guard let url = URL(string: "\(host)/api/tags") else {
            completion?(cachedModels)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                DispatchQueue.main.async { completion?(self?.cachedModels ?? []) }
                return
            }

            do {
                let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                var valid: [String] = []
                for m in tags.models {
                    let name = m.name
                    let caps = m.capabilities ?? []
                    if caps.contains("embedding") && !caps.contains("completion") {
                        continue
                    }
                    if name.lowercased().contains("embedding") {
                        continue
                    }
                    if !name.isEmpty {
                        valid.append(name)
                    }
                }
                if !valid.isEmpty {
                    self.cachedModels = valid
                    if !valid.contains(self.modelName) && !self.modelName.isEmpty {
                        self.cachedModels.insert(self.modelName, at: 0)
                    }
                }
                DispatchQueue.main.async { completion?(self.cachedModels) }
            } catch {
                DispatchQueue.main.async { completion?(self.cachedModels) }
            }
        }.resume()
    }

    public func checkHealth(completion: @escaping (Bool, [String]) -> Void) {
        fetchModels { models in
            completion(!models.isEmpty, models)
        }
    }

    public func freeVRAM(completion: ((Bool, String) -> Void)? = nil) {
        guard let psUrl = URL(string: "\(host)/api/ps") else {
            completion?(false, "Invalid URL")
            return
        }

        URLSession.shared.dataTask(with: psUrl) { [weak self] data, response, error in
            guard let self = self else { return }
            var modelsToUnload = Set<String>()
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                for m in models {
                    if let name = (m["name"] as? String) ?? (m["model"] as? String), !name.isEmpty {
                        modelsToUnload.insert(name)
                    }
                }
            }
            if !self.modelName.isEmpty {
                modelsToUnload.insert(self.modelName)
            }

            let group = DispatchGroup()
            for m in modelsToUnload {
                guard let genUrl = URL(string: "\(self.host)/api/generate") else { continue }
                var req = URLRequest(url: genUrl)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = ["model": m, "keep_alive": 0]
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                req.timeoutInterval = 5.0
                group.enter()
                URLSession.shared.dataTask(with: req) { _, _, _ in
                    group.leave()
                }.resume()
            }

            group.notify(queue: .main) {
                completion?(true, "VRAM Freed!")
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
        onComplete: @escaping (Result<String, Error>) -> Void,
        sourceLang: String = "Auto",
        targetLang: String = "Chinese",
        sourceMode: String = "Auto",
        targetMode: String = "Manual"
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

        let systemPrompt: String
        if sourceMode == "Auto" && targetMode == "Auto" {
            systemPrompt = "You are a professional multilingual translator. Automatically detect the source language. If the input is in Chinese, translate it into fluent, natural English. If the input is in English or any other language, translate it into fluent, natural Simplified Chinese. Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
        } else if sourceMode == "Auto" {
            systemPrompt = "You are a professional multilingual translator. Automatically detect the source language of the input and translate it into fluent, natural \(targetLang). Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
        } else if targetMode == "Auto" {
            systemPrompt = "You are a professional multilingual translator. Translate the \(sourceLang) user input into fluent, natural Simplified Chinese (or into English if the input is Chinese). Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
        } else {
            systemPrompt = "You are a professional multilingual translator. Translate the following \(sourceLang) user input into fluent, natural \(targetLang). Output ONLY the translation directly. Never include pinyin, notes, commentary, quotes, or markdown explanations."
        }

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
