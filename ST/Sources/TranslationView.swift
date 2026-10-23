import SwiftUI

public class TranslationViewModel: ObservableObject {
    @Published public var originalText: String = ""
    @Published public var translatedText: String = ""
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var isPinned: Bool = false
    @Published public var copiedToast: Bool = false
    @Published public var elapsedTimeMs: Int = 0

    public var onClose: (() -> Void)?

    private var startTime: Date?

    public init() {}

    public func startTranslation(source: String) {
        self.originalText = source
        self.translatedText = ""
        self.errorMessage = nil
        self.isLoading = true
        self.copiedToast = false
        self.elapsedTimeMs = 0
        self.startTime = Date()

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
            }
        )
    }

    public func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)

        copiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedToast = false
        }
    }
}

public struct TranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header bar
            HStack(spacing: 8) {
                // ST Brand Pill
                HStack(spacing: 5) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                    Text("ST")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.85), Color.purple.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(6)

                // Model tag
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isLoading ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text("gemma4:e4b")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(5)

                Spacer()

                // Actions: Copy
                Button(action: {
                    viewModel.copyTranslation()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: viewModel.copiedToast ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        if viewModel.copiedToast {
                            Text("Copied")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundColor(viewModel.copiedToast ? .green : .secondary)
                    .padding(4)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Copy translation to clipboard")

                // Actions: Pin
                Button(action: {
                    viewModel.isPinned.toggle()
                }) {
                    Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(viewModel.isPinned ? .orange : .secondary)
                        .padding(4)
                        .background(viewModel.isPinned ? Color.orange.opacity(0.15) : Color.primary.opacity(0.05))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(viewModel.isPinned ? "Unpin window (allow auto-dismiss)" : "Pin window (keep visible)")

                // Actions: Close
                Button(action: {
                    viewModel.onClose?()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(4)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Close popup (Esc)")
            }

            // Original snippet (truncated with subtle style)
            if !viewModel.originalText.isEmpty {
                Text(viewModel.originalText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 2)
            }

            Divider()
                .opacity(0.4)

            // Translation Content
            Group {
                if let err = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Translation Error")
                                .font(.system(size: 13, weight: .bold))
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else if viewModel.isLoading && viewModel.translatedText.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Translating with Gemma 4...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(viewModel.translatedText)
                                .font(.system(size: 14.5, weight: .regular))
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if viewModel.isLoading {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 5, height: 5)
                                    .opacity(0.8)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }

            // Footer metadata
            if viewModel.elapsedTimeMs > 0 || viewModel.isPinned {
                HStack {
                    if viewModel.elapsedTimeMs > 0 {
                        Text("\(viewModel.elapsedTimeMs) ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    Spacer()
                    if viewModel.isPinned {
                        Text("📌 Pinned")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    } else {
                        Text("Click outside or Esc to close")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(
            ZStack {
                VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}

// Visual Effect Backdrop Helper for macOS
public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
