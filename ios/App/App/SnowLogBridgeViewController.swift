import Capacitor
import Foundation

final class SnowLogBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(SnowLogTimerPlugin())
        bridge?.registerPluginInstance(SnowLogHeartRatePlugin())
        bridge?.registerPluginInstance(SnowLogBackupPlugin())
    }

    func openActiveWorkout() {
        let script = "window.snowLogOpenActiveWorkout && window.snowLogOpenActiveWorkout();"
        webView?.evaluateJavaScript(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.webView?.evaluateJavaScript(script)
        }
    }
}
