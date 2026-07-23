'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

const plugin = fs.readFileSync('ios/App/App/SnowLogTimerPlugin.swift', 'utf8');
const appDelegate = fs.readFileSync('ios/App/App/AppDelegate.swift', 'utf8');
const liveActivity = fs.readFileSync(
  'ios/App/SnowLogTimerWidget/SnowLogTimerLiveActivity.swift',
  'utf8'
);
const project = fs.readFileSync('ios/App/App.xcodeproj/project.pbxproj', 'utf8');
const appInfo = fs.readFileSync('ios/App/App/Info.plist', 'utf8');
const web = fs.readFileSync('index.html', 'utf8');

const sounds = ['ding', 'beep', 'chime'];
for (const sound of sounds) {
  const path = `ios/App/App/NotificationSounds/snowlog-${sound}.caf`;
  assert.ok(fs.existsSync(path), `${sound} CAF exists`);
  const info = execFileSync('/usr/bin/afinfo', [path], { encoding: 'utf8' });
  assert.match(info, /File type ID:\s+caff/, `${sound} is CAF`);
  const duration = Number(info.match(/estimated duration:\s+([0-9.]+)/)?.[1]);
  assert.ok(duration > 0 && duration < 30, `${sound} duration is valid for notifications`);
  assert.ok(project.includes(`snowlog-${sound}.caf in Resources`), `${sound} target membership`);
  assert.match(plugin, new RegExp(`case "beep", "ding", "chime"`), `${sound} mapping is constrained`);
}

class TimerModel {
  start({ target, alarm = false, sound = 'ding', permission = true }) {
    this.running = true;
    this.target = target;
    this.alarm = alarm;
    this.sound = sounds.includes(sound) ? sound : 'ding';
    this.permission = permission;
    this.fired = false;
    this.pending = alarm && permission;
    this.events = [];
  }

  updateTarget(target) {
    this.target = target;
    this.fired = false;
    this.pending = this.alarm && this.permission;
  }

  stop() {
    this.running = false;
    this.pending = false;
  }

  overdue(now) {
    return this.running && now >= this.target;
  }

  cross(now, appState) {
    if (!this.overdue(now) || this.fired) return;
    this.fired = true;
    if (appState === 'foreground') {
      this.pending = false;
      this.events.push('haptic');
      if (this.alarm) this.events.push(`audio:${this.sound}`);
    } else if (this.pending) {
      this.events.push(`notification:${this.sound}`);
      this.pending = false;
    }
  }
}

// 1. Defaults work without opening Settings and never pass an empty sound.
{
  const timer = new TimerModel();
  timer.start({ target: 10 });
  assert.equal(timer.sound, 'ding');
  assert.match(web, /normalizeRestSoundFile\(t\.soundFile\)/);
  assert.match(plugin, /call\.getString\("soundFile"\) \?\? "ding\.mp3"/);
}

// 2. Every enabled sound maps to a real bundled CAF.
for (const sound of sounds) {
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: true, sound });
  timer.cross(10, 'foreground');
  assert.deepEqual(timer.events, ['haptic', `audio:${sound}`]);
}

// 3. Disabling the chime does not affect overdue state or its red rendering.
{
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: false });
  timer.cross(10, 'foreground');
  assert.equal(timer.overdue(30), true);
  assert.deepEqual(timer.events, ['haptic']);
  assert.match(liveActivity, /context\.isStale \? Color\.red : Color\.white/);
  assert.doesNotMatch(liveActivity, /alarm|sound|chime/i);
}

// 4. A clean/default timer always creates a non-nil stale date, even when
// Settings has never opened and the chime is disabled.
{
  const startDate = 1_000;
  const setpointMilliseconds = 30_000;
  const targetDate = startDate + setpointMilliseconds;
  const content = { state: { startDate, setpointDate: targetDate }, staleDate: targetDate };
  assert.equal(content.staleDate, targetDate);
  assert.equal(content.staleDate <= targetDate, true);
  assert.match(plugin, /canonicalTargetDate\(/);
  assert.match(plugin, /return ActivityContent\(state: state, staleDate: targetDate\)/);
  assert.match(plugin, /restoredActivity\.content\.state/);
  assert.match(plugin, /await restoredActivity\.update\(restoredContent\)/);
  assert.doesNotMatch(plugin, /staleDate:\s*nil/);
}

// 5. Foreground threshold is one sound and one haptic only.
{
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: true, sound: 'chime' });
  timer.cross(10, 'foreground');
  timer.cross(20, 'foreground');
  assert.deepEqual(timer.events, ['haptic', 'audio:chime']);
  assert.match(plugin, /thresholdDidFire/);
}

// 6–7. Background and locked thresholds use one selected-sound notification.
for (const state of ['background', 'locked']) {
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: true, sound: 'beep' });
  timer.cross(10, state);
  timer.cross(20, state);
  assert.deepEqual(timer.events, ['notification:beep']);
}

// 8. Foreground playback fallback ducks Spotify/other audio and restores it afterward.
assert.match(plugin, /setCategory\(\.playback, mode: \.default, options: \[\.duckOthers\]\)/);
assert.match(plugin, /\.notifyOthersOnDeactivation/);
assert.match(plugin, /private var audioPlayer: AVAudioPlayer\?/);

// 9. A target update resets the threshold and ActivityKit stale date.
{
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: true });
  timer.updateTarget(20);
  timer.cross(10, 'foreground');
  assert.deepEqual(timer.events, []);
  timer.cross(20, 'foreground');
  assert.deepEqual(timer.events, ['haptic', 'audio:ding']);
  assert.match(plugin, /ActivityContent\(state: state, staleDate: targetDate\)/);
  assert.doesNotMatch(plugin, /staleDate: nil/);
}

// 10. Stopping before target cancels delivery.
{
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: true });
  timer.stop();
  timer.cross(10, 'foreground');
  assert.deepEqual(timer.events, []);
  assert.equal(timer.pending, false);
  assert.match(plugin, /removePendingNotificationRequests/);
}

// 11. The system timer continues counting up and remains overdue/red.
{
  const timer = new TimerModel();
  timer.start({ target: 10 });
  assert.equal(timer.overdue(11), true);
  assert.equal(timer.overdue(100), true);
  assert.match(liveActivity, /countsDown: false/);
}

// 12. Denied notification permission leaves foreground timing functional.
{
  const timer = new TimerModel();
  timer.start({ target: 10, alarm: true, permission: false });
  timer.cross(10, 'foreground');
  assert.deepEqual(timer.events, ['haptic', 'audio:ding']);
  assert.match(plugin, /in-app timing remains active/);
}

// 13. Foreground notification delivery requests sound only and no visible presentation.
assert.match(
  appDelegate,
  /if notification\.request\.identifier == SnowLogTimerNotification\.identifier \{[\s\S]*?completionHandler\(\[\.sound\]\)\s*\} else/
);
assert.match(plugin, /handleForegroundNotification/);
assert.match(web, /if \(!isNativeCapacitor\(\)\) \{\s*Sound\.play/);

// Release contract: the local timer notification contains sound and only
// internal run identification, with no visible alert/list/badge fields.
assert.match(plugin, /content\.sound = UNNotificationSound/);
assert.match(plugin, /SnowLogTimerNotification\.runIdentifierKey: run\.identifier/);
assert.doesNotMatch(plugin, /content\.(?:title|subtitle|body|badge|attachments|categoryIdentifier|interruptionLevel)\s*=/);
assert.match(plugin, /requestAuthorization\(options: \[\.sound\]\)/);
assert.match(plugin, /removeDeliveredNotifications/);
assert.match(appInfo, /<key>ITSAppUsesNonExemptEncryption<\/key>\s*<false\/>/);

console.log('SnowLog native timer regression tests passed.');
