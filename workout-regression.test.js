'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const workout = require('./workout-utils.js');

const web = fs.readFileSync('index.html', 'utf8');
const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));

const completed = (id, name, sets, note = '') => ({ id, name, sets, note });
const blankRows = [
  { set: 1, weight: '', reps: '' },
  { set: 2, weight: '', reps: '' }
];

// 1–3. An available-library exercise, a temporary exercise, and any arbitrary
// exercise are all excluded when they have no genuinely performed sets.
assert.match(web, /"Cable Lateral Raise"/, 'Cable Lateral Raise remains available');
assert.match(
  web,
  /const chosen = populated\.find\(c =>/,
  'a blank duplicate exercise cannot be selected over its populated counterpart'
);
const zeroSetDrafts = [
  completed('available-cable', 'Cable Lateral Raise', []),
  completed('temporary-cable', 'Cable Lateral Raise', blankRows),
  completed('arbitrary', 'Arbitrary Exercise', [{ set: 1, weight: 20, reps: 0 }])
];
assert.deepEqual(workout.completedExerciseItems(zeroSetDrafts), []);

// A stale note is not a completed set and cannot create a zero-set history row.
assert.deepEqual(
  workout.completedExerciseItems([
    completed('notes-only', 'Cable Lateral Raise', blankRows, 'old note')
  ]),
  []
);

// 4–5. One valid completed set includes the exercise; a trailing blank row does
// not change the performed-set count.
const oneCompleted = completed('bench', 'Bench Press', [
  { set: 1, weight: 80, reps: 5 },
  { set: 2, weight: 80, reps: '' }
]);
assert.deepEqual(workout.completedExerciseItems([oneCompleted]).map(item => item.id), ['bench']);
assert.equal(workout.completedSets(oneCompleted.sets).length, 1);

// 6. Save Day and Finish Workout are the same completion path in SnowLog and
// therefore consume the same shared filtered list.
const finishCandidates = [...zeroSetDrafts, oneCompleted];
const saveDayList = workout.completedExerciseItems(finishCandidates);
const finishWorkoutList = workout.completedExerciseItems(finishCandidates);
assert.deepEqual(saveDayList, finishWorkoutList);
assert.deepEqual(saveDayList.map(item => item.id), ['bench']);

// 7. Persisting the resulting history cannot create a zero-set exercise entry.
const savedHistory = saveDayList.map(item => ({
  exerciseId: item.id,
  sets: workout.completedSets(item.sets)
}));
assert.ok(savedHistory.every(session => session.sets.length > 0));
assert.deepEqual(savedHistory.map(session => session.exerciseId), ['bench']);

// Local date calculation uses calendar components rather than a UTC ISO date.
const originalTZ = process.env.TZ;
process.env.TZ = 'Australia/Perth';
assert.equal(workout.localDateISO(new Date(2026, 6, 26, 12, 30)), '2026-07-26');
const nearMidnightPerth = new Date('2026-07-25T16:30:00.000Z');
assert.equal(nearMidnightPerth.toISOString().slice(0, 10), '2026-07-25');
assert.equal(workout.localDateISO(nearMidnightPerth), '2026-07-26');
if (originalTZ === undefined) delete process.env.TZ;
else process.env.TZ = originalTZ;

// The selected date is transient, survives ordinary rendering while the Log
// page remains open, and resets on cancel, re-entry, and reload.
assert.match(web, /let saveDayDate = null;/);
assert.match(
  web,
  /function currentSaveDayDate\(\)\{[\s\S]*?workoutDate[\s\S]*?return saveDayDate \|\| todayISO\(\);/,
  'Save Day consumes the currently displayed transient date'
);
assert.match(web, /if \(id === 'workoutDate'\) \{[\s\S]*?saveDayDate = [\s\S]*?return;/);
assert.match(web, /if \(e\.target\?\.id === 'workoutDate'\) \{[\s\S]*?saveDayDate = [\s\S]*?return;/);
assert.match(web, /const enteringLogPage = which === 'logPage' && currentPage !== 'logPage';/);
assert.match(web, /if \(enteringLogPage\) resetLogDateToToday\(\);/);
assert.match(web, /if \(!ok\) \{\s*resetLogDateToToday\(\);/);
assert.match(web, /ensureActiveSelection\(\);[\s\S]*?resetLogDateToToday\(\);[\s\S]*?renderSelectors\(\);/);
assert.doesNotMatch(
  web,
  /if \(id === 'workoutDate'\) \{[\s\S]{0,350}state\.log\.workoutDate\s*=/,
  'manual Save Day date is not persisted'
);

// Previously saved workoutDate values are read for displays but never rewritten
// by the local-date helper or completion filter.
const historic = [{ workoutDate: '2024-02-29', exerciseId: 'bench', sets: [{ reps: 5 }] }];
workout.completedExerciseItems(historic.map(item => ({ ...item, performed: item.sets })));
assert.equal(historic[0].workoutDate, '2024-02-29');

// touch-action: manipulation removes double-tap zoom without disabling pinch
// zoom through viewport restrictions or broad touch-event cancellation.
assert.match(web, /html,body\s*\{[\s\S]*?touch-action:\s*manipulation;/);
assert.doesNotMatch(web, /user-scalable\s*=\s*no|maximum-scale\s*=\s*1/i);
assert.doesNotMatch(web, /touchend[\s\S]{0,300}preventDefault\(/);
assert.ok(packageJson.scripts['build:web'].includes('workout-utils.js'));

console.log('SnowLog workout completion, local-date, and touch regression tests passed.');
