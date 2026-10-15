import Foundation
import PonteCamera

// CameraProbe: Ponte's camera link (CameraLink) alone, for the end-to-end test of the Ponte Camera extension
// (camera/test/e2e.mjs with PONTE_LINK=1).
//   CameraProbe [--port N]
// Prints "status <listening> <failed> <clients> <cameras>" on every change; reads lines "publish <json>" from stdin
// and publishes them; exits when stdin closes.
var port = CameraRules.linkPort
let argv = CommandLine.arguments
if let i = argv.firstIndex(of: "--port"), i + 1 < argv.count, let n = Int(argv[i + 1]) { port = n }
setvbuf(stdout, nil, _IOLBF, 0)
let link = CameraLink(port: port)
link.onStatus = { listening, failed, clients, cameras in
    print("status \(listening ? 1 : 0) \(failed ? 1 : 0) \(clients) \(cameras)")
}
link.start()
DispatchQueue.global().async {
    while let line = readLine() {
        if line.hasPrefix("publish ") { link.publish(Data(line.dropFirst(8).utf8)) }
    }
    link.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
}
dispatchMain()
