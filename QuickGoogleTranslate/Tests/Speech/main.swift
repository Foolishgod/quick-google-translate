import AVFoundation
import NaturalLanguage

func check(_ value: Bool, _ label: String) {
    guard value else { fputs("FAIL: " + label + "\n", stderr); exit(1) }
    print("PASS: " + label)
}
final class Engine: SpeechSynthesizing {
    var delegate: AVSpeechSynthesizerDelegate?
    var utterances: [AVSpeechUtterance] = []
    var stops = 0
    func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance) }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { stops += 1; return true }
}
check(SpeechLanguage.resolve(text: "bank", preferred: nil) == "en-US", "English words select an English voice automatically")
check(SpeechLanguage.resolve(text: "你好，世界", preferred: nil).hasPrefix("zh-"), "Chinese text selects a Chinese voice automatically")
check(SpeechLanguage.resolve(text: "こんにちは", preferred: nil) == "ja", "Japanese text is recognized")
check(SpeechLanguage.resolve(text: "bank", preferred: "fr-FR") == "fr-FR", "Explicit target language wins over ambiguous short text")
check(SpeechLanguage.resolve(text: "Hello", preferred: "zh_Hant") == "zh-TW", "Language tags normalize to supported voice locales")
let engine = Engine()
let controller = ReadAloudController(engine: engine)
var changes = 0
controller.onChange = { changes += 1 }
do { try controller.toggle(.source, text: " \n ", language: nil); check(false,"Empty text must fail") } catch {}
check(engine.utterances.isEmpty && controller.section == nil, "Empty text never starts speech")
try controller.toggle(.source, text: "  Hello world.  ", language: "en-US")
let first = engine.utterances[0]
check(first.speechString == "Hello world." && first.voice!.language.hasPrefix("en"), "Speech uses the current trimmed text and selected voice")
controller.stopUnlessReadingSource(" Hello world. ")
check(controller.section == .source && engine.stops == 0, "Translating the same draft keeps its source speech playing")
try controller.toggle(.translation, text: "你好，世界。", language: "zh-CN")
let second = engine.utterances[1]
check(engine.stops == 1 && controller.section == .translation && changes >= 3, "Switching sections stops the old utterance and updates controls")
let callbackEngine = AVSpeechSynthesizer()
controller.speechSynthesizer(callbackEngine, didCancel: first)
check(controller.section == .translation, "Late cancellation of the previous utterance cannot stop the new one")
controller.speechSynthesizer(callbackEngine, didFinish: first)
check(controller.section == .translation, "Late completion of the previous utterance is ignored")
controller.speechSynthesizer(callbackEngine, didFinish: second)
check(controller.section == nil, "Natural completion returns the controls to idle")
try controller.toggle(.source, text: "Hello", language: "en-US")
try controller.toggle(.source, text: "Hello", language: "en-US")
check(controller.section == nil && engine.stops == 2, "Clicking the active section stops immediately")
let count = changes
controller.stop()
check(changes == count, "Stopping idle speech does not produce extra callbacks")
let missingEngine = Engine()
let missing = ReadAloudController(engine: missingEngine, voice: { _ in nil })
do { try missing.toggle(.source, text: "Hello", language: "en-US"); check(false,"Missing voice must fail") } catch {}
check(missingEngine.utterances.isEmpty && missing.section == nil, "Missing voices show an error without starting speech")

// Render through the real system engine to verify usable voice data without
// playing audio through the user's speakers or accessing a microphone.
if CommandLine.arguments.contains("--render") {
    for (language, text) in [("en-US", "Hello, world."), ("zh-CN", "你好，世界。") ] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        check(utterance.voice != nil, "System voice exists: " + language)
        var frames: UInt64 = 0
        var finished = false
        var nonSilent = false
        let lock = NSLock()
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            var signal = false
            if let samples = pcm.floatChannelData?[0] { signal = (0..<Int(pcm.frameLength)).contains { abs(samples[$0]) > 0.00001 } }
            else if let samples = pcm.int16ChannelData?[0] { signal = (0..<Int(pcm.frameLength)).contains { samples[$0] != 0 } }
            lock.lock(); frames += UInt64(pcm.frameLength); nonSilent = nonSilent || signal; if pcm.frameLength == 0 { finished = true }; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            lock.lock(); let done = finished; lock.unlock()
            if done { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        lock.lock(); let total = frames; let done = finished; let signal = nonSilent; lock.unlock()
        check(total > 0 && done && signal, "Real system voice generates complete audio: " + language)
    }
}
print("All read-aloud checks passed; no audio played, settings or permissions changed.")
