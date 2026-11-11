# Timer delivery validation

The prior native path awaited ActivityKit reconciliation before scheduling its
deadline. It also consumed and discarded a foreground callback more than two
seconds late, and had no active-state reconciliation for temporary interruptions.
These are confirmed code defects, not proof of the cause of a particular device
incident. Input focus does not drive native delivery.

Now: completed-set transition → timerToggle → Capacitor start → native absolute
deadline scheduling → notification scheduling → ActivityKit reconciliation.
Native dispatch and notification-delegate callbacks share one run gate. An early
callback rearms; a late foreground callback delivers and logs its lateness.
Background crossings remain notification-owned on return. Future target changes
receive a new native run identifier. No page or input callback fires native audio.

Console category RestTimer records native delivery, lateness, duplicate suppression,
audio requests/results and haptics. JS [RestTimer] records start dates, page changes,
focus/blur and visibility without field values or Health/workout contents.

## Physical-device acceptance (not yet executed)

For each of Ding, Beep and Chime, use a short target and verify one sound and one
haptic without touching the screen at the deadline:

- Log with no focus, weight focus, reps focus, keyboard dismissed, and no interaction.
- Scroll throughout crossing; navigate away; return before crossing.
- Background before crossing; lock before crossing; background and return before it.
- Let the target pass without any UI event.
- Change to a future target; reset before target; disable chime.
- Complete sets 1, 2, 3, 4 and the final set. Edit a completed set: no new start.
- Save Day after final-set rest: timer stops normally.

Compare targetDate against native threshold and audio-start logs. Record any
lateness and app state. CSS/UI interaction and simulator builds alone cannot
certify real-device sound delivery or haptic sensation. The existing disabled-chime
behavior retains haptics and overdue display while suppressing sound.
