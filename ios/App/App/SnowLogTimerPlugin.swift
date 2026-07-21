import ActivityKit
import Capacitor
import UIKit
import UserNotifications

@objc(SnowLogTimerPlugin)
final class SnowLogTimerPlugin: CAPInstancePlugin, CAPBridgedPlugin {
    let identifier = "SnowLogTimerPlugin"
    let jsName = "SnowLogTimer"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]

    private let notificationIdentifier = "snowlog-rest-timer-setpoint"
    private var activity: Activity<SnowLogTimerAttributes>?
    private var hapticWorkItem: DispatchWorkItem?

    override func load() {
        activity = Activity<SnowLogTimerAttributes>.activities.first
    }

    @objc func start(_ call: CAPPluginCall) {
        guard let startDate = date(fromMilliseconds: call.getDouble("startedAtMs")),
              let setpointMilliseconds = call.getDouble("setpointMs") else {
            call.reject("A start time and setpoint are required.")
            return
        }

        let alarmEnabled = call.getBool("alarmEnabled") ?? false
        let soundFile = call.getString("soundFile") ?? "chime.mp3"
        let setpointDate = startDate.addingTimeInterval(setpointMilliseconds / 1_000)

        Task { @MainActor in
            await endActivity()
            await beginActivity(startDate: startDate, setpointDate: setpointDate)
            await replaceNotification(
                at: setpointDate,
                soundFile: soundFile,
                enabled: alarmEnabled,
                requestPermission: alarmEnabled
            )
            call.resolve()
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        guard let startDate = date(fromMilliseconds: call.getDouble("startedAtMs")),
              let setpointMilliseconds = call.getDouble("setpointMs") else {
            call.reject("A start time and setpoint are required.")
            return
        }

        let alarmEnabled = call.getBool("alarmEnabled") ?? false
        let soundFile = call.getString("soundFile") ?? "chime.mp3"
        let setpointDate = startDate.addingTimeInterval(setpointMilliseconds / 1_000)

        Task { @MainActor in
            await updateActivity(startDate: startDate, setpointDate: setpointDate)
            await replaceNotification(
                at: setpointDate,
                soundFile: soundFile,
                enabled: alarmEnabled,
                requestPermission: false
            )
            call.resolve()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        Task { @MainActor in
            await cancelNotification()
            await endActivity()
            call.resolve()
        }
    }

    @MainActor
    private func beginActivity(startDate: Date, setpointDate: Date) async {
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = SnowLogTimerAttributes(workoutURL: "snowlog://workout")
        let state = SnowLogTimerAttributes.ContentState(startDate: startDate, setpointDate: setpointDate)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            CAPLog.print("SnowLog Live Activity could not start: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func updateActivity(startDate: Date, setpointDate: Date) async {
        guard #available(iOS 16.1, *) else { return }
        let state = SnowLogTimerAttributes.ContentState(startDate: startDate, setpointDate: setpointDate)
        if let activity {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        } else {
            await beginActivity(startDate: startDate, setpointDate: setpointDate)
        }
    }

    @MainActor
    private func endActivity() async {
        hapticWorkItem?.cancel()
        hapticWorkItem = nil
        guard #available(iOS 16.1, *) else { return }
        let activities = Activity<SnowLogTimerAttributes>.activities
        for currentActivity in activities {
            await currentActivity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    @MainActor
    private func replaceNotification(
        at setpointDate: Date,
        soundFile: String,
        enabled: Bool,
        requestPermission: Bool
    ) async {
        await cancelNotification()
        scheduleForegroundHaptic(at: setpointDate, enabled: enabled)
        guard enabled else { return }

        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if requestPermission && settings.authorizationStatus == .notDetermined {
            // The rest timer only needs permission to play its selected sound.
            // Omitting `.alert` prevents SnowLog from requesting banner permission.
            _ = try? await center.requestAuthorization(options: [.sound])
            settings = await center.notificationSettings()
        }
        let notificationIsAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        guard notificationIsAuthorized, settings.soundSetting == .enabled else { return }

        let content = UNMutableNotificationContent()
        // Sound-only content deliberately has no title, body, badge or userInfo,
        // so reaching the setpoint doesn't create a visible notification.
        content.sound = UNNotificationSound(named: notificationSoundName(for: soundFile))

        let interval = max(1, setpointDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    @MainActor
    private func cancelNotification() async {
        hapticWorkItem?.cancel()
        hapticWorkItem = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }

    @MainActor
    private func scheduleForegroundHaptic(at setpointDate: Date, enabled: Bool) {
        guard enabled else { return }
        let workItem = DispatchWorkItem {
            guard UIApplication.shared.applicationState == .active else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        hapticWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, setpointDate.timeIntervalSinceNow), execute: workItem)
    }

    private func notificationSoundName(for webSoundFile: String) -> UNNotificationSoundName {
        let baseName = URL(fileURLWithPath: webSoundFile).deletingPathExtension().lastPathComponent
        switch baseName {
        case "beep", "ding", "chime":
            return UNNotificationSoundName("snowlog-\(baseName).caf")
        default:
            return UNNotificationSoundName("snowlog-chime.caf")
        }
    }

    private func date(fromMilliseconds value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1_000)
    }
}
