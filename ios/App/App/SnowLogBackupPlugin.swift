import Capacitor
import UIKit

@objc(SnowLogBackupPlugin)
final class SnowLogBackupPlugin: CAPInstancePlugin, CAPBridgedPlugin {
    let identifier = "SnowLogBackupPlugin"
    let jsName = "SnowLogBackup"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "exportBackup", returnType: CAPPluginReturnPromise)
    ]

    @objc func exportBackup(_ call: CAPPluginCall) {
        guard let json = call.getString("json"), !json.isEmpty else {
            call.reject("The backup is empty.")
            return
        }

        let requestedName = call.getString("fileName") ?? "workout_logger_backup.json"
        let safeName = URL(fileURLWithPath: requestedName).lastPathComponent
        guard safeName.lowercased().hasSuffix(".json") else {
            call.reject("The backup filename is invalid.")
            return
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnowLogBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(safeName, isDirectory: false)
            try Data(json.utf8).write(to: fileURL, options: .atomic)

            DispatchQueue.main.async { [weak self] in
                guard let self, let presenter = self.bridge?.viewController else {
                    call.reject("SnowLog could not open the iOS share sheet.")
                    return
                }
                let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                }
                presenter.present(activity, animated: true) {
                    call.resolve()
                }
            }
        } catch {
            call.reject("SnowLog could not create the backup file.", nil, error)
        }
    }
}
