import Foundation
import PonteCamera

// CameraProbe: Ponte's camera link (CameraLink) alone, for the end-to-end test of the Ponte Camera extension
// (camera/test/e2e.mjs with PONTE_LINK=1).
//   CameraProbe [--port N]
// Prints "status <listening> <failed> <clients> <processed> <passing> <troubled>" on every change (and "error <stage>
// <renderer> <name>: <message>" when a page reports one); reads lines "publish <json>" from stdin and publishes them;
// exits when stdin closes.
var port = CameraRules.linkPort
let argv = CommandLine.arguments
if let i = argv.firstIndex(of: "--port"), i + 1 < argv.count, let n = Int(argv[i + 1]) { port = n }
setvbuf(stdout, nil, _IOLBF, 0)
let link = CameraLink(port: port)
link.onStatus = { s in
    print("status \(s.listening ? 1 : 0) \(s.failed ? 1 : 0) \(s.clients) \(s.processed) \(s.passing) \(s.troubled)")
    if let e = s.error { print("error \(e.stage) \(e.renderer) \(e.name): \(e.message)") }
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
