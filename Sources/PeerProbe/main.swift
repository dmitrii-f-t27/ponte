import AVFoundation
import Foundation
import PonteAudio
import PontePeer

// PeerProbe: a second "Russian" for checking «Русские в звонке» without a second person.
//   PeerProbe --relay wss://host/r/ --secret abcd-efgh-jkmn [--seconds N] [--send ru.wav] [--say "texto em português"]
//             [--own S] [--out received.wav]
// Joins the room, prints the link status, streams a WAV as its "voice" (real time, 40 ms frames), announces a
// Portuguese TTS phrase (--say, 3 s) or «Свой голос» (--own seconds), and writes what it hears to --out.

var options: [String: String] = [:]
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    let key = argv[i]
    if key.hasPrefix("--"), i + 1 < argv.count { options[key] = argv[i + 1]; i += 2 } else { i += 1 }
}
guard let relayText = options["--relay"], let relay = URL(string: relayText),
      let secret = options["--secret"].flatMap(PeerRules.secretNormalized) else {
    print("usage: PeerProbe --relay wss://host/r/ --secret abcd-efgh-jkmn [--seconds N] [--send ru.wav] [--say text] [--own S] [--out file.wav]")
    exit(2)
}
let seconds = Double(options["--seconds"] ?? "15") ?? 15

let link = PeerLink(relay: relay, secret: secret)
let lock = NSLock()
var received: [Float] = []
var frames = 0
var voices: [String] = []
link.onStatus = { status, peers in print("status \(status) peers \(peers)") }
link.onAudio = { _, buffer in
    lock.withLock {
        frames += 1
        if let data = buffer.floatChannelData {
            received.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
    }
}
link.onVoice = { event in
    let line = "voice kind \(event.kind) state \(event.state) text \"\(event.text)\""
    print(line)
    lock.withLock { voices.append(line) }
}
link.start()
print("sender \(link.sender)")

// Wait for the socket, then act.
DispatchQueue.global().async {
    Thread.sleep(forTimeInterval: 2)
    if let say = options["--say"] {
        print("say start: \(say)")
        link.sendVoice(kind: PeerRules.voiceTTS, state: PeerRules.voiceStart, text: say)
        Thread.sleep(forTimeInterval: 3)
        link.sendVoice(kind: PeerRules.voiceTTS, state: PeerRules.voiceEnd, text: say)
        print("say end")
    }
    if let own = options["--own"].flatMap(Double.init) {
        print("own voice start")
        link.sendVoice(kind: PeerRules.voiceOwn, state: PeerRules.voiceStart, text: "")
        Thread.sleep(forTimeInterval: own)
        link.sendVoice(kind: PeerRules.voiceOwn, state: PeerRules.voiceEnd, text: "")
        print("own voice end")
    }
    if let path = options["--send"] {
        do {
            let buffer = try FileSource.readMono(url: URL(fileURLWithPath: path))
            let chunk = Int(buffer.format.sampleRate * 0.04)
            var at = 0
            let total = Int(buffer.frameLength)
            print("sending \(path): \(String(format: "%.1f", Double(total) / buffer.format.sampleRate)) s")
            while at < total, let piece = PCM.slice(buffer, at ..< min(total, at + chunk)) {
                link.sendMicrophone(piece)
                at += chunk
                Thread.sleep(forTimeInterval: 0.04)
            }
            print("sent")
        } catch {
            print("cannot read \(path): \(error)")
        }
    }
}

RunLoop.main.run(until: Date().addingTimeInterval(seconds))
link.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))

let (heard, count, events) = lock.withLock { (received, frames, voices) }
print("received \(count) audio frames, \(String(format: "%.1f", Double(heard.count) / PeerRules.sampleRate)) s, \(events.count) voice events")
if let out = options["--out"], !heard.isEmpty {
    let buffer = PCM.buffer(heard, sampleRate: PeerRules.sampleRate)
    do {
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: buffer.format.settings)
        try file.write(from: buffer)
        print("wrote \(out)")
    } catch {
        print("cannot write \(out): \(error)")
    }
}
