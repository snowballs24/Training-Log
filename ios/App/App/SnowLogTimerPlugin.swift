import ActivityKit
import AVFoundation
import Capacitor
import OSLog
import UIKit
import UserNotifications

enum SnowLogTimerNotification {
    static let identifier = "snowlog-rest-timer-setpoint"
    static let categoryIdentifier = "snowlog-rest-timer"
    static let runIdentifierKey = "snowlogTimerRunIdentifier"
    static let workoutURLKey = "url"
}

@MainActor
final class SnowLogTimerDeliveryCoordinator: NSObject, AVAudioPlayerDelegate {
    static let shared = SnowLogTimerDeliveryCoordinator()

    private struct Run {
        let identifier: String
        let targetDate: Date
        let alarmEnabled: Bool
        let soundFile: String
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bensnow.snowlog",
        category: "RestTimer"
    )
    private var run: Run?
    private var thresholdWorkItem: DispatchWorkItem?
    private var hapticPrepareWorkItem: DispatchWorkItem?
    private var preparedHaptic: UIImpactFeedbackGenerator?
    private var thresholdDidFire = false
    private var foregroundSoundHandledRunIdentifier: String?
    private var audioPlayer: AVAudioPlayer?

    func start(
        targetDate: Date,
        alarmEnabled: Bool,
        webSoundFile: String,
        requestPermission: Bool
    ) async {
        await stop()
        let selectedSound = Self.notificationSoundFile(for: webSoundFile)
        run = Run(
            identifier: UUID().uuidString,
            targetDate: targetDate,
            alarmEnabled: alarmEnabled,
            soundFile: selectedSound
        )
        thresholdDidFire = false
        foregroundSoundHandledRunIdentifier = nil
        logger.info(
            "Starting timer delivery; target=\(targetDate.timeIntervalSince1970, privacy: .public), alarm=\(alarmEnabled, privacy: .public), sound=\(selectedSound, privacy: .public)"
        )
        scheduleForegroundThreshold()
        await replaceNotification(requestPermission: requestPermission)
    }

    func update(
        targetDate: Date,
        alarmEnabled: Bool,
        webSoundFile: String
    ) async {
        guard let existingRun = run else {
            await start(
                targetDate: targetDate,
                alarmEnabled: alarmEnabled,
                webSoundFile: webSoundFile,
                requestPermission: false
            )
            return
        }

        let targetChanged = abs(existingRun.targetDate.timeIntervalSince(targetDate)) > 0.001
        let selectedSound = Self.notificationSoundFile(for: webSoundFile)
        run = Run(
            identifier: existingRun.identifier,
            targetDate: targetDate,
            alarmEnabled: alarmEnabled,
            soundFile: selectedSound
        )
        if targetChanged {
            thresholdDidFire = false
            foregroundSoundHandledRunIdentifier = nil
        }
        logger.info(
            "Updating timer delivery; targetChanged=\(targetChanged, privacy: .public), alarm=\(alarmEnabled, privacy: .public), sound=\(selectedSound, privacy: .public)"
        )
        scheduleForegroundThreshold()
        await replaceNotification(requestPermission: false)
    }

    func stop() async {
        thresholdWorkItem?.cancel()
        thresholdWorkItem = nil
        hapticPrepareWorkItem?.cancel()
        hapticPrepareWorkItem = nil
        preparedHaptic = nil
        thresholdDidFire = false
        foregroundSoundHandledRunIdentifier = nil
        run = nil
        await cancelNotification()
        stopAudioPlayback()
        logger.info("Stopped timer delivery and cancelled pending timer notification")
    }

    func ensureBackgroundNotification() async {
        guard let run, run.targetDate > Date(), run.alarmEnabled else { return }
        logger.info("App entered background; ensuring one timer notification remains scheduled")
        await replaceNotification(requestPermission: false)
    }

    func handleForegroundNotification(_ notification: UNNotification) -> Bool {
        guard notification.request.content.categoryIdentifier == SnowLogTimerNotification.categoryIdentifier,
              let identifier = notification.request.content.userInfo[SnowLogTimerNotification.runIdentifierKey] as? String else {
            return false
        }
        return fireForegroundThreshold(runIdentifier: identifier, source: "notification delegate")
    }

    private func scheduleForegroundThreshold() {
        thresholdWorkItem?.cancel()
        hapticPrepareWorkItem?.cancel()
        preparedHaptic = nil
        guard let run, !thresholdDidFire else { return }

        let prepareDelay = run.targetDate.timeIntervalSinceNow - 1
        if prepareDelay > 0 {
            let runIdentifier = run.identifier
            let prepareItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.run?.identifier == runIdentifier,
                      UIApplication.shared.applicationState == .active else { return }
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.prepare()
                self.preparedHaptic = generator
                self.logger.debug("Prepared foreground timer haptic")
            }
            hapticPrepareWorkItem = prepareItem
            DispatchQueue.main.asyncAfter(deadline: .now() + prepareDelay, execute: prepareItem)
        }

        let runIdentifier = run.identifier
        let thresholdItem = DispatchWorkItem { [weak self] in
            _ = self?.fireForegroundThreshold(runIdentifier: runIdentifier, source: "native target date")
        }
        thresholdWorkItem = thresholdItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, run.targetDate.timeIntervalSinceNow),
            execute: thresholdItem
        )
    }

    private func fireForegroundThreshold(runIdentifier: String, source: String) -> Bool {
        guard let run, run.identifier == runIdentifier else { return false }
        if thresholdDidFire {
            return foregroundSoundHandledRunIdentifier == runIdentifier
        }
        guard Date() >= run.targetDate else { return false }

        thresholdDidFire = true
        thresholdWorkItem?.cancel()
        thresholdWorkItem = nil
        hapticPrepareWorkItem?.cancel()
        hapticPrepareWorkItem = nil

        let deliveryLateness = Date().timeIntervalSince(run.targetDate)
        guard deliveryLateness < 2 else {
            preparedHaptic = nil
            logger.info(
                "Skipped delayed foreground delivery \(deliveryLateness, privacy: .public) seconds after target; background notification owns that crossing"
            )
            return false
        }

        guard UIApplication.shared.applicationState == .active else {
            preparedHaptic = nil
            logger.info("Timer reached its target outside the foreground; relying on the local notification")
            return false
        }

        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [SnowLogTimerNotification.identifier]
        )

        let haptic = preparedHaptic ?? UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred(intensity: 0.65)
        preparedHaptic = nil
        logger.info("Triggered one foreground timer haptic from \(source, privacy: .public)")

        guard run.alarmEnabled else {
            logger.info("Foreground timer sound is disabled; overdue state and haptic remain active")
            return true
        }

        let didStartSound = playForegroundSound(named: run.soundFile)
        if didStartSound {
            foregroundSoundHandledRunIdentifier = runIdentifier
        }
        return didStartSound
    }

    private func playForegroundSound(named soundFile: String) -> Bool {
        let fileURL = URL(fileURLWithPath: soundFile)
        let resourceName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        guard !resourceName.isEmpty,
              !fileExtension.isEmpty,
              let bundledURL = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) else {
            logger.error("Foreground timer sound was not found in the app bundle: \(soundFile, privacy: .public)")
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: bundledURL)
            player.delegate = self
            player.numberOfLoops = 0
            player.prepareToPlay()
            guard player.play() else {
                logger.error("AVAudioPlayer refused to start timer sound: \(soundFile, privacy: .public)")
                deactivateAudioSession()
                return false
            }
            audioPlayer = player
            logger.info("Started foreground timer sound with duckOthers: \(soundFile, privacy: .public)")
            return true
        } catch {
            logger.error(
                "Foreground timer audio setup failed for \(soundFile, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            deactivateAudioSession()
            return false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.logger.info("Foreground timer sound finished; success=\(flag, privacy: .public)")
            self?.audioPlayer = nil
            self?.deactivateAudioSession()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            if let error {
                self?.logger.error(
                    "Foreground timer sound decode failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            self?.audioPlayer = nil
            self?.deactivateAudioSession()
        }
    }

    private func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            logger.error(
                "Could not deactivate foreground timer audio session: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func replaceNotification(requestPermission: Bool) async {
        await cancelNotification()
        guard let run, run.alarmEnabled, run.targetDate > Date() else {
            logger.info("No background timer notification required")
            return
        }

        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        logger.info(
            "Timer notification authorization=\(settings.authorizationStatus.rawValue, privacy: .public), alertSetting=\(settings.alertSetting.rawValue, privacy: .public), soundSetting=\(settings.soundSetting.rawValue, privacy: .public)"
        )

        if requestPermission && settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                logger.info("Timer notification permission request completed; granted=\(granted, privacy: .public)")
            } catch {
                logger.error(
                    "Timer notification permission request failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            settings = await center.notificationSettings()
        }

        let notificationIsAuthorized =
            settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        guard notificationIsAuthorized else {
            logger.error(
                "Timer notification was not scheduled because authorization is unavailable; in-app timing remains active"
            )
            return
        }
        guard settings.soundSetting == .enabled else {
            logger.error(
                "Timer notification was not scheduled because notification sounds are disabled; in-app timing remains active"
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Rest timer reached"
        content.body = "SnowLog’s rest timer reached its target."
        content.categoryIdentifier = SnowLogTimerNotification.categoryIdentifier
        content.userInfo = [
            SnowLogTimerNotification.workoutURLKey: "snowlog://workout",
            SnowLogTimerNotification.runIdentifierKey: run.identifier
        ]
        content.sound = UNNotificationSound(named: UNNotificationSoundName(run.soundFile))

        let interval = run.targetDate.timeIntervalSinceNow
        guard interval > 0 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        let request = UNNotificationRequest(
            identifier: SnowLogTimerNotification.identifier,
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            logger.info(
                "Scheduled one timer notification; sound=\(run.soundFile, privacy: .public), interval=\(interval, privacy: .public)"
            )
        } catch {
            logger.error(
                "Could not schedule timer notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func cancelNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [SnowLogTimerNotification.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [SnowLogTimerNotification.identifier])
    }

    static func notificationSoundFile(for webSoundFile: String?) -> String {
        let suppliedValue = webSoundFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseName = URL(fileURLWithPath: suppliedValue)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        switch baseName {
        case "beep", "ding", "chime":
            return "snowlog-\(baseName).caf"
        default:
            return "snowlog-ding.caf"
        }
    }
}

@objc(SnowLogTimerPlugin)
final class SnowLogTimerPlugin: CAPInstancePlugin, CAPBridgedPlugin {
    let identifier = "SnowLogTimerPlugin"
    let jsName = "SnowLogTimer"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bensnow.snowlog",
        category: "RestTimer"
    )
    private var activity: Activity<SnowLogTimerAttributes>?

    override func load() {
        activity = Activity<SnowLogTimerAttributes>.activities.first
        logger.info("Loaded native timer plugin and restored any existing Live Activity")
    }

    @objc func start(_ call: CAPPluginCall) {
        guard let startDate = date(fromMilliseconds: call.getDouble("startedAtMs")),
              let setpointMilliseconds = call.getDouble("setpointMs"),
              setpointMilliseconds.isFinite,
              setpointMilliseconds > 0 else {
            call.reject("A valid start time and setpoint are required.")
            return
        }

        let alarmEnabled = call.getBool("alarmEnabled") ?? false
        let soundFile = call.getString("soundFile") ?? "ding.mp3"
        let setpointDate = startDate.addingTimeInterval(setpointMilliseconds / 1_000)

        Task { @MainActor in
            await endActivity()
            await beginActivity(startDate: startDate, setpointDate: setpointDate)
            await SnowLogTimerDeliveryCoordinator.shared.start(
                targetDate: setpointDate,
                alarmEnabled: alarmEnabled,
                webSoundFile: soundFile,
                requestPermission: alarmEnabled
            )
            call.resolve()
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        guard let startDate = date(fromMilliseconds: call.getDouble("startedAtMs")),
              let setpointMilliseconds = call.getDouble("setpointMs"),
              setpointMilliseconds.isFinite,
              setpointMilliseconds > 0 else {
            call.reject("A valid start time and setpoint are required.")
            return
        }

        let alarmEnabled = call.getBool("alarmEnabled") ?? false
        let soundFile = call.getString("soundFile") ?? "ding.mp3"
        let setpointDate = startDate.addingTimeInterval(setpointMilliseconds / 1_000)

        Task { @MainActor in
            await updateActivity(startDate: startDate, setpointDate: setpointDate)
            await SnowLogTimerDeliveryCoordinator.shared.update(
                targetDate: setpointDate,
                alarmEnabled: alarmEnabled,
                webSoundFile: soundFile
            )
            call.resolve()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        Task { @MainActor in
            await SnowLogTimerDeliveryCoordinator.shared.stop()
            await endActivity()
            call.resolve()
        }
    }

    @MainActor
    private func beginActivity(startDate: Date, setpointDate: Date) async {
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are unavailable or disabled")
            return
        }
        let attributes = SnowLogTimerAttributes(workoutURL: "snowlog://workout")
        let state = SnowLogTimerAttributes.ContentState(
            startDate: startDate,
            setpointDate: setpointDate
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: setpointDate),
                pushType: nil
            )
            logger.info(
                "Started Live Activity with staleDate=\(setpointDate.timeIntervalSince1970, privacy: .public)"
            )
        } catch {
            logger.error(
                "SnowLog Live Activity could not start: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @MainActor
    private func updateActivity(startDate: Date, setpointDate: Date) async {
        guard #available(iOS 16.1, *) else { return }
        let state = SnowLogTimerAttributes.ContentState(
            startDate: startDate,
            setpointDate: setpointDate
        )
        if let activity {
            await activity.update(
                ActivityContent(state: state, staleDate: setpointDate)
            )
            logger.info(
                "Updated Live Activity target and staleDate=\(setpointDate.timeIntervalSince1970, privacy: .public)"
            )
        } else {
            await beginActivity(startDate: startDate, setpointDate: setpointDate)
        }
    }

    @MainActor
    private func endActivity() async {
        guard #available(iOS 16.1, *) else { return }
        for currentActivity in Activity<SnowLogTimerAttributes>.activities {
            await currentActivity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        logger.info("Ended all SnowLog timer Live Activities")
    }

    private func date(fromMilliseconds value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1_000)
    }
}
