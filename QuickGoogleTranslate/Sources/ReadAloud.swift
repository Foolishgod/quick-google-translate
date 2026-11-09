import AVFoundation
import NaturalLanguage

enum SpeechSection { case source, translation }

enum ReadAloudError: LocalizedError {
    case empty, missingVoice
    var errorDescription: String? {
        switch self {
        case .empty: return "请先输入文字或等待译文生成。"
        case .missingVoice: return "此语言暂无可用的系统语音，请在系统设置的朗读语音中添加。"
        }
    }
}

enum SpeechLanguage {
    static func resolve(text: String, preferred: String?) -> String {
        let hint = preferred?.replacingOccurrences(of: "_", with: "-")
        let language = (hint?.isEmpty == false && hint != "auto") ? hint! : (NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en")
        switch language {
        case "zh", "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "en": return "en-US"
        default: return language
        }
    }
}

protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}
extension AVSpeechSynthesizer: SpeechSynthesizing {}

final class ReadAloudController: NSObject, AVSpeechSynthesizerDelegate {
    private let engine: SpeechSynthesizing
    private let voice: (String) -> AVSpeechSynthesisVoice?
    private var utterance: AVSpeechUtterance?
    private(set) var section: SpeechSection?
    var onChange: (() -> Void)?

    init(engine: SpeechSynthesizing = AVSpeechSynthesizer(), voice: @escaping (String) -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(language: $0) }) {
        self.engine = engine; self.voice = voice
        super.init()
        engine.delegate = self
    }

    func toggle(_ section: SpeechSection, text: String, language: String?) throws {
        if self.section == section { stop(); return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReadAloudError.empty }
        let code = SpeechLanguage.resolve(text: text, preferred: language)
        guard let selectedVoice = voice(code) else { throw ReadAloudError.missingVoice }
        stop()
        let next = AVSpeechUtterance(string: text)
        next.voice = selectedVoice
        next.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance = next; self.section = section
        onChange?()
        engine.speak(next)
    }

    func stop() {
        guard utterance != nil else { return }
        // Retire the old utterance before stopping: its cancel callback can be
        // synchronous or arrive after another section has already started.
        utterance = nil; section = nil
        engine.stopSpeaking(at: .immediate)
        onChange?()
    }

    func stopUnlessReadingSource(_ text: String) {
        if section == .source && utterance?.speechString == text.trimmingCharacters(in: .whitespacesAndNewlines) { return }
        stop()
    }

    private func completed(_ completed: AVSpeechUtterance) {
        let finish = { [weak self] in
            guard let self, self.utterance === completed else { return }
            self.utterance = nil; self.section = nil
            self.onChange?()
        }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { completed(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { completed(utterance) }
}
