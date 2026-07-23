import ActivityKit
import AVFoundation
import Capacitor
import OSLog
import UIKit
import UserNotifications

enum SnowLogTimerNotification {
    static let identifier = "snowlog-rest-timer-setpoint"
    static let runIdentifierKey = "snowlogTimerRunIdentifier"
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
    private var preparedHaptic: UINotificationFeedbackGenerator?
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

    func handleForegroundNotification(_ notification: UNNotification) {
        guard notification.request.identifier == SnowLogTimerNotification.identifier,
              let identifier = notification.request.content.userInfo[SnowLogTimerNotification.runIdentifierKey] as? String else {
            return
        }
        _ = fireForegroundThreshold(
            runIdentifier: identifier,
            source: "notification delegate"
        )
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
                let generator = UINotificationFeedbackGenerator()
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

        let haptic = preparedHaptic ?? UINotificationFeedbackGenerator()
        haptic.notificationOccurred(.warning)
        preparedHaptic = nil
        logger.info("Triggered one foreground warning haptic from \(source, privacy: .public)")

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
        logNotificationSettings(settings, context: "before scheduling")

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
            logNotificationSettings(settings, context: "after permission request")
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
        content.title = "Rest timer"
        content.body = "Setpoint reached"
        content.userInfo = [
            SnowLogTimerNotification.runIdentifierKey: run.identifier
        ]
        content.sound = UNNotificationSound(named: UNNotificationSoundName(run.soundFile))

        let interval = run.targetDate.timeIntervalSinceNow
        guard interval > 0 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: SnowLogTimerNotification.identifier,
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            logger.info(
                "Scheduled one timer notification; target=\(run.targetDate.timeIntervalSince1970, privacy: .public), sound=\(run.soundFile, privacy: .public), interval=\(interval, privacy: .public)"
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

    private func logNotificationSettings(
        _ settings: UNNotificationSettings,
        context: String
    ) {
        logger.info(
            "Timer notification settings \(context, privacy: .public); authorizationStatus=\(settings.authorizationStatus.rawValue, privacy: .public), soundSetting=\(settings.soundSetting.rawValue, privacy: .public), alertSetting=\(settings.alertSetting.rawValue, privacy: .public), lockScreenSetting=\(settings.lockScreenSetting.rawValue, privacy: .public), notificationCenterSetting=\(settings.notificationCenterSetting.rawValue, privacy: .public), alertStyle=\(settings.alertStyle.rawValue, privacy: .public)"
        )
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconcileAfterAppBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        guard let restoredActivity = activity else {
            logger.info("Loaded native timer plugin with no existing Live Activity")
            return
        }

        let restoredState = restoredActivity.content.state
        let targetDuration = restoredState.setpointDate.timeIntervalSince(restoredState.startDate)
        guard let canonical = canonicalActivityContent(
            startDate: restoredState.startDate,
            targetDuration: targetDuration
        ) else {
            logger.error("Could not reconcile restored Live Activity because its timer values are invalid")
            return
        }
        Task { @MainActor [weak self] in
            await self?.reconcileLiveActivity(
                canonical: canonical,
                initiator: "native launch restoration",
                chimeEnabled: nil
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reconcileAfterAppBecameActive() {
        guard let currentActivity = currentSnowLogActivity() else { return }
        let state = currentActivity.content.state
        let targetDuration = state.setpointDate.timeIntervalSince(state.startDate)
        guard let canonical = canonicalActivityContent(
            startDate: state.startDate,
            targetDuration: targetDuration
        ) else { return }
        Task { @MainActor [weak self] in
            await self?.reconcileLiveActivity(
                canonical: canonical,
                initiator: "app-state reconciliation",
                chimeEnabled: nil
            )
        }
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
        let initiator = diagnosticInitiator(
            call.getString("initiator"),
            fallback: "javascript timer start"
        )
        guard let canonical = canonicalActivityContent(
            startDate: startDate,
            targetDuration: setpointMilliseconds / 1_000
        ) else {
            call.reject("The timer target could not be calculated.")
            return
        }

        Task { @MainActor in
            await reconcileLiveActivity(
                canonical: canonical,
                initiator: initiator,
                chimeEnabled: alarmEnabled
            )
            await SnowLogTimerDeliveryCoordinator.shared.start(
                targetDate: canonical.targetDate,
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
        let initiator = diagnosticInitiator(
            call.getString("initiator"),
            fallback: "javascript timer update"
        )
        guard let canonical = canonicalActivityContent(
            startDate: startDate,
            targetDuration: setpointMilliseconds / 1_000
        ) else {
            call.reject("The timer target could not be calculated.")
            return
        }

        Task { @MainActor in
            await reconcileLiveActivity(
                canonical: canonical,
                initiator: initiator,
                chimeEnabled: alarmEnabled
            )
            await SnowLogTimerDeliveryCoordinator.shared.update(
                targetDate: canonical.targetDate,
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

    private struct CanonicalActivityContent {
        let startDate: Date
        let targetDuration: TimeInterval
        let targetDate: Date
        let content: ActivityContent<SnowLogTimerAttributes.ContentState>
    }

    private func canonicalActivityContent(
        startDate: Date,
        targetDuration: TimeInterval
    ) -> CanonicalActivityContent? {
        guard startDate.timeIntervalSince1970.isFinite,
              targetDuration.isFinite,
              targetDuration > 0 else {
            return nil
        }
        let targetDate = startDate.addingTimeInterval(targetDuration)
        let state = SnowLogTimerAttributes.ContentState(
            startDate: startDate,
            setpointDate: targetDate
        )
        let content = ActivityContent(state: state, staleDate: targetDate)
        return CanonicalActivityContent(
            startDate: startDate,
            targetDuration: targetDuration,
            targetDate: targetDate,
            content: content
        )
    }

    @MainActor
    private func reconcileLiveActivity(
        canonical: CanonicalActivityContent,
        initiator: String,
        chimeEnabled: Bool?
    ) async {
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are unavailable or disabled")
            return
        }

        let activities = Activity<SnowLogTimerAttributes>.activities
        let currentActivity = currentSnowLogActivity(from: activities)
        if let currentActivity {
            activity = currentActivity
            await applyCanonicalContent(
                to: currentActivity,
                initiator: initiator,
                operation: "update",
                canonical: canonical,
                chimeEnabled: chimeEnabled
            )
            for extraActivity in activities where extraActivity.id != currentActivity.id {
                await extraActivity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let attributes = SnowLogTimerAttributes(workoutURL: "snowlog://workout")
        do {
            let newActivity = try Activity.request(
                attributes: attributes,
                content: canonical.content,
                pushType: nil
            )
            activity = newActivity
            logActivityContent(
                initiator: initiator,
                operation: "request",
                canonical: canonical,
                activityIdentifier: newActivity.id,
                chimeEnabled: chimeEnabled
            )
            // A real-device regression showed that the system did not refresh
            // isStale for newly requested content until a later settings
            // update. Apply the same canonical content immediately so initial
            // start and later updates take the identical ActivityKit path.
            await applyCanonicalContent(
                to: newActivity,
                initiator: initiator,
                operation: "post-request reconciliation update",
                canonical: canonical,
                chimeEnabled: chimeEnabled
            )
        } catch {
            logger.error(
                "SnowLog Live Activity request from \(initiator, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @MainActor
    private func applyCanonicalContent(
        to targetActivity: Activity<SnowLogTimerAttributes>,
        initiator: String,
        operation: String,
        canonical: CanonicalActivityContent,
        chimeEnabled: Bool?
    ) async {
        await targetActivity.update(canonical.content)
        logActivityContent(
            initiator: initiator,
            operation: operation,
            canonical: canonical,
            activityIdentifier: targetActivity.id,
            chimeEnabled: chimeEnabled
        )
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

    private func currentSnowLogActivity(
        from activities: [Activity<SnowLogTimerAttributes>] = Activity<SnowLogTimerAttributes>.activities
    ) -> Activity<SnowLogTimerAttributes>? {
        if let activity,
           let matchingActivity = activities.first(where: { $0.id == activity.id }) {
            return matchingActivity
        }
        return activities.first
    }

    private func logActivityContent(
        initiator: String,
        operation: String,
        canonical: CanonicalActivityContent,
        activityIdentifier: String,
        chimeEnabled: Bool?
    ) {
        let staleDate = canonical.content.staleDate?.timeIntervalSince1970 ?? -1
        let chimeValue = chimeEnabled.map(String.init) ?? "unknown"
        logger.info(
            "Live Activity \(operation, privacy: .public); initiator=\(initiator, privacy: .public), start=\(canonical.startDate.timeIntervalSince1970, privacy: .public), targetDuration=\(canonical.targetDuration, privacy: .public), target=\(canonical.targetDate.timeIntervalSince1970, privacy: .public), content.staleDate=\(staleDate, privacy: .public), activityID=\(activityIdentifier, privacy: .public), chime=\(chimeValue, privacy: .public)"
        )
    }

    private func diagnosticInitiator(_ suppliedValue: String?, fallback: String) -> String {
        switch suppliedValue {
        case "javascript timer start",
             "javascript chime toggle",
             "javascript target-duration change",
             "javascript sound change",
             "javascript timer update":
            return suppliedValue ?? fallback
        default:
            return fallback
        }
    }

    private func date(fromMilliseconds value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1_000)
    }
}
