import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AppKit

final class SpeechModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    @Published private(set) var speaking = false
    @Published private(set) var paused = false
    @Published private(set) var exporting = false
    @Published var status = ""

    let voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices().sorted {
        if $0.language != $1.language { return $0.language < $1.language }
        return $0.name < $1.name
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voiceID: String, rate: Float, pitch: Float) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = voice }
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        synthesizer.speak(utterance)
        speaking = true
        paused = false
    }

    func togglePause() {
        if paused {
            synthesizer.continueSpeaking()
            paused = false
        } else {
            synthesizer.pauseSpeaking(at: .word)
            paused = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
        paused = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speaking = false
            self.paused = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speaking = false
            self.paused = false
        }
    }

    /// Exports speech to an audio file using the built-in `say` command.
    func export(_ text: String, voiceName: String, rate: Float) {
        guard let url = Panels.saveFile(name: "Speech.aiff", types: [.aiff]) else { return }
        exporting = true
        status = "Exporting…"
        let words = Int(min(max(175 * (rate / AVSpeechUtteranceDefaultSpeechRate), 80), 500))
        DispatchQueue.global(qos: .userInitiated).async {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mactools-speech.txt")
            try? text.write(to: temp, atomically: true, encoding: .utf8)
            var result = Shell.runSync("/usr/bin/say", ["-v", voiceName, "-r", "\(words)", "-o", url.path, "-f", temp.path])
            if !result.succeeded {
                result = Shell.runSync("/usr/bin/say", ["-r", "\(words)", "-o", url.path, "-f", temp.path])
            }
            try? FileManager.default.removeItem(at: temp)
            let finalResult = result
            DispatchQueue.main.async {
                self.exporting = false
                self.status = finalResult.succeeded ? "Saved \(url.lastPathComponent)" : "Export failed: \(finalResult.combined)"
                if finalResult.succeeded { Panels.reveal(url) }
            }
        }
    }
}

struct SpeechView: View {
    @StateObject private var model = SpeechModel()
    @AppStorage("speechText") private var text = "Hello! I'm your Mac. Type anything here and I'll read it out loud."
    @AppStorage("speechVoice") private var voiceID = ""
    @AppStorage("speechRate") private var rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("speechPitch") private var pitch: Double = 1.0
    @State private var languageFilter = ""

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        if languageFilter.isEmpty { return model.voices }
        return model.voices.filter {
            $0.language.localizedCaseInsensitiveContains(languageFilter) || $0.name.localizedCaseInsensitiveContains(languageFilter)
        }
    }

    private var selectedVoiceName: String {
        AVSpeechSynthesisVoice(identifier: voiceID)?.name ?? "Samantha"
    }

    var body: some View {
        ToolPage(tool: .speech) {
            Card(title: "Text", icon: "text.quote") {
                CodeEditor(text: $text, minHeight: 150, monospaced: false)
                    .frame(height: 170)
                HStack {
                    Button {
                        model.speak(text, voiceID: voiceID, rate: Float(rate), pitch: Float(pitch))
                    } label: {
                        Label("Speak", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmed.isEmpty)
                    Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                        .disabled(!model.speaking)
                    Button("Stop") { model.stop() }
                        .disabled(!model.speaking)
                    Button("Speak Clipboard") {
                        if let clip = ClipboardHelper.string {
                            text = clip
                            model.speak(clip, voiceID: voiceID, rate: Float(rate), pitch: Float(pitch))
                        }
                    }
                    Spacer()
                    Button("Export Audio…") {
                        model.export(text, voiceName: selectedVoiceName, rate: Float(rate))
                    }
                    .disabled(model.exporting || text.trimmed.isEmpty)
                }
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Card(title: "Voice", icon: "person.wave.2") {
                HStack {
                    TextField("Filter voices (e.g. en-GB, Daniel)", text: $languageFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Picker("Voice", selection: $voiceID) {
                        Text("System default").tag("")
                        ForEach(filteredVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                    Button("Reset") { rate = Double(AVSpeechUtteranceDefaultSpeechRate) }
                }
                HStack {
                    Text("Pitch")
                    Slider(value: $pitch, in: 0.5...2.0)
                    Button("Reset") { pitch = 1.0 }
                }
                Text("Download more (and higher quality) voices in System Settings ▸ Accessibility ▸ Spoken Content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
