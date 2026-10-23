import SwiftUI

public let SUPPORTED_LANGUAGES: [String] = [
    "English",
    "Chinese",
    "French",
    "German",
    "Japanese",
    "Korean",
    "Russian"
]

public func detectLanguage(_ text: String) -> String {
    let cyrillicCount = text.unicodeScalars.filter { $0.value >= 0x0400 && $0.value <= 0x04FF }.count
    if cyrillicCount >= 2 { return "Russian" }

    let hangulCount = text.unicodeScalars.filter { $0.value >= 0xAC00 && $0.value <= 0xD7AF }.count
    if hangulCount >= 2 { return "Korean" }

    let japaneseCount = text.unicodeScalars.filter { $0.value >= 0x3040 && $0.value <= 0x30FF }.count
    if japaneseCount >= 2 { return "Japanese" }

    let hanziCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
    if hanziCount >= 2 { return "Chinese" }

    let lower = text.lowercased()
    let germanMarkers = ["ä", "ö", "ü", "ß", " und ", " der ", " die ", " das ", " ist ", " nicht "]
    if germanMarkers.contains(where: { lower.contains($0) }) { return "German" }

    let frenchMarkers = ["é", "è", "ê", "à", "ç", "œ", "ù", " et ", " le ", " la ", " les ", " est ", " dans "]
    if frenchMarkers.contains(where: { lower.contains($0) }) { return "French" }

    return "English"
}

public class TranslationViewModel: ObservableObject {
    @Published public var originalText: String = ""
    @Published public var translatedText: String = ""
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var elapsedTimeMs: Int = 0

    @Published public var sourceMode: String = "Auto"
    @Published public var sourceLang: String = "English"
    @Published public var targetMode: String = "Manual"
    @Published public var targetLang: String = "Chinese"
    @Published public var activeModel: String = "gemma4:e4b"
    @Published public var availableModels: [String] = ["gemma4:e4b"]

    public var isPinned: Bool = false
    public var onClose: (() -> Void)?
    private var startTime: Date?

    public var effectiveSourceLang: String {
        if sourceMode == "Auto" && !originalText.isEmpty {
            return detectLanguage(originalText)
        }
        return sourceLang
    }

    public var targetDisplay: String {
        if targetMode == "Auto" {
            return "Chinese/English"
        }
        return targetLang
    }

    public init() {
        loadConfig()
        refreshModels()
    }

    public func loadConfig() {
        let configURL = URL(fileURLWithPath: "config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = json["model"] as? String, !m.isEmpty {
                self.activeModel = m
                OllamaService.shared.setModel(m)
            }
            if let sm = json["source_mode"] as? String { self.sourceMode = sm }
            if let sl = json["source_lang"] as? String { self.sourceLang = sl }
            if let tm = json["target_mode"] as? String { self.targetMode = tm }
            if let tl = json["target_lang"] as? String { self.targetLang = tl }
        }
    }

    public func saveConfig() {
        var dict: [String: Any] = [:]
        let configURL = URL(fileURLWithPath: "config.json")
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }
        dict["model"] = activeModel
        dict["source_mode"] = sourceMode
        dict["source_lang"] = sourceLang
        dict["target_mode"] = targetMode
        dict["target_lang"] = targetLang

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: configURL)
        }
    }

    public func refreshModels() {
        OllamaService.shared.fetchModels { [weak self] models in
            DispatchQueue.main.async {
                self?.availableModels = models
            }
        }
    }

    public func setModel(_ model: String) {
        self.activeModel = model
        OllamaService.shared.setModel(model)
        saveConfig()
        if !originalText.isEmpty {
            startTranslation(source: originalText)
        }
    }

    public func setSourceMode(_ mode: String) {
        self.sourceMode = mode
        saveConfig()
        if !originalText.isEmpty {
            startTranslation(source: originalText)
        }
    }

    public func setSourceLang(_ lang: String) {
        self.sourceLang = lang
        self.sourceMode = "Manual"
        saveConfig()
        if !originalText.isEmpty {
            startTranslation(source: originalText)
        }
    }

    public func setTargetMode(_ mode: String) {
        self.targetMode = mode
        saveConfig()
        if !originalText.isEmpty {
            startTranslation(source: originalText)
        }
    }

    public func setTargetLang(_ lang: String) {
        self.targetLang = lang
        self.targetMode = "Manual"
        saveConfig()
        if !originalText.isEmpty {
            startTranslation(source: originalText)
        }
    }

    public func swapLanguages() {
        let tempLang = sourceLang
        sourceLang = targetLang
        targetLang = tempLang
        sourceMode = "Manual"
        targetMode = "Manual"
        saveConfig()
        if !originalText.isEmpty {
            startTranslation(source: originalText)
        }
    }

    public func startTranslation(source: String) {
        self.originalText = source
        self.translatedText = ""
        self.errorMessage = nil
        self.isLoading = true
        self.elapsedTimeMs = 0
        self.startTime = Date()

        let sLang = effectiveSourceLang
        let tLang = targetLang
        let sMode = sourceMode
        let tMode = targetMode

        OllamaService.shared.translateStream(
            text: source,
            onToken: { [weak self] token in
                guard let self = self else { return }
                self.isLoading = false
                self.translatedText += token
            },
            onComplete: { [weak self] result in
                guard let self = self else { return }
                self.isLoading = false
                if let start = self.startTime {
                    self.elapsedTimeMs = Int(Date().timeIntervalSince(start) * 1000)
                }

                switch result {
                case .success(let fullText):
                    self.translatedText = fullText
                case .failure(let error):
                    if self.translatedText.isEmpty {
                        self.errorMessage = error.localizedDescription
                    }
                }
            },
            sourceLang: sLang,
            targetLang: tLang,
            sourceMode: sMode,
            targetMode: tMode
        )
    }
}

public struct TranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 1. Header with Source controls, Swap arrow, Target controls, Model selector, and Latency
            HStack(spacing: 5) {
                // Source Language Column
                VStack(alignment: .leading, spacing: 1) {
                    Menu {
                        Button("Auto Detect") { viewModel.setSourceMode("Auto") }
                        Button("Manual Selection") { viewModel.setSourceMode("Manual") }
                    } label: {
                        Text("\(viewModel.sourceMode) ▾")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(red: 0.39, green: 0.45, blue: 0.55)) // #64748b
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Menu {
                        ForEach(SUPPORTED_LANGUAGES, id: \.self) { lang in
                            Button(lang) { viewModel.setSourceLang(lang) }
                        }
                    } label: {
                        Text("\(viewModel.effectiveSourceLang) ▾")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.80, green: 0.84, blue: 0.88)) // #cbd5e1
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                // Swap Button
                Button(action: {
                    viewModel.swapLanguages()
                }) {
                    Text("⇄")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.39, green: 0.45, blue: 0.55))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Swap Source & Target Languages")

                // Target Language Column
                VStack(alignment: .leading, spacing: 1) {
                    Menu {
                        Button("Auto Detect") { viewModel.setTargetMode("Auto") }
                        Button("Manual Selection") { viewModel.setTargetMode("Manual") }
                    } label: {
                        Text("\(viewModel.targetMode) ▾")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(red: 0.39, green: 0.45, blue: 0.55))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Menu {
                        ForEach(SUPPORTED_LANGUAGES, id: \.self) { lang in
                            Button(lang) { viewModel.setTargetLang(lang) }
                        }
                    } label: {
                        Text("\(viewModel.targetLang) ▾")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.80, green: 0.84, blue: 0.88))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Spacer()

                // Model Selector Button
                Menu {
                    ForEach(viewModel.availableModels, id: \.self) { model in
                        Button(model) { viewModel.setModel(model) }
                    }
                } label: {
                    Text("\(viewModel.activeModel) ▾")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(red: 0.39, green: 0.45, blue: 0.55))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                // Latency Label
                if viewModel.elapsedTimeMs > 0 {
                    Text("\(viewModel.elapsedTimeMs) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0.28, green: 0.33, blue: 0.41)) // #475569
                }
            }

            // Divider line
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // 2. Translated Text Box (NO SRC section, direct translation with scrolling)
            Group {
                if let err = viewModel.errorMessage {
                    Text("Error: \(err)")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.94, green: 0.27, blue: 0.27)) // #ef4444
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if viewModel.isLoading && viewModel.translatedText.isEmpty {
                    Text("Translating (\(viewModel.effectiveSourceLang) → \(viewModel.targetDisplay)) with \(viewModel.activeModel)...")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundColor(Color(red: 0.39, green: 0.45, blue: 0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(viewModel.translatedText)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(Color(red: 0.97, green: 0.98, blue: 0.99)) // #f8fafc
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 9, trailing: 14))
        .frame(width: 415, height: 185)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.086, green: 0.090, blue: 0.114)) // #16171d
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}
