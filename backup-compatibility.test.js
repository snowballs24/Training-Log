'use strict';

const assert = require('node:assert/strict');
const backupApi = require('./backup.js');

class MemoryStorage {
  constructor(entries = {}, failOnceOnKey = null) {
    this.values = new Map(Object.entries(entries));
    this.failOnceOnKey = failOnceOnKey;
  }
  getItem(key) { return this.values.has(key) ? this.values.get(key) : null; }
  setItem(key, value) {
    if (this.failOnceOnKey === key) {
      this.failOnceOnKey = null;
      throw new Error('simulated storage failure');
    }
    this.values.set(key, String(value));
  }
  removeItem(key) { this.values.delete(key); }
}

const representativeState = {
  routines: [{ id: 'routine-1', name: 'Strength', days: [{ id: 'day-1', name: 'Push', exercises: [{ id: 'bench', name: 'Bench Press' }] }] }],
  activeRoutineId: 'routine-1',
  sessions: [{ id: 'session-1', date: '2026-07-20', routineId: 'routine-1', dayId: 'day-1', sets: [{ exerciseId: 'bench', weight: 80, reps: 5 }] }],
  log: { dayId: 'day-1', prepared: { bench: [{ weight: '82.5', reps: '5' }] }, notes: { bench: 'Paused' }, workoutDate: '2026-07-21', exerciseContexts: {}, isActive: true },
  wiz: { editingId: null, name: '', daysCount: 0, dayNames: [], dayExercises: {} },
  uiPrevWeeks: { bench: 3 }, uiPrevWeeksAll: 2, uiTimers: {},
  uiTimer: { running: false, start: 0, elapsed: 0, interval: null, alarmEnabled: true, alarmAtMs: 90000, alarmFired: false, soundFile: 'ding.mp3' },
  uiOpen: { bench: true }, trendsDayId: 'day-1', uiTrendsCollapsed: false,
  tempExercises: { '2026-07-21|day-1': [{ id: 'custom-1', name: 'Custom Raise', category: 'Shoulders' }] },
  exerciseNames: { bench: 'Bench Press', 'custom-1': 'Custom Raise' }
};
const representativePrefs = {
  units: 'kg', accent: 'sunset', surface: 'solid', carryOverWeights: true,
  shareExerciseHistory: true, weeklyWorkoutTarget: 5, pinnedExerciseIds: ['bench', 'custom-1']
};
const defaultState = {
  routines: [], activeRoutineId: null, sessions: [],
  log: { dayId: null, prepared: {}, notes: {}, workoutDate: null, exerciseContexts: {}, isActive: false },
  wiz: {}, uiPrevWeeks: {}, uiPrevWeeksAll: 1, uiTimers: {}, uiTimer: {}, uiOpen: {},
  trendsDayId: null, uiTrendsCollapsed: true, tempExercises: {}, exerciseNames: {}
};
const defaultPrefs = {
  units: 'kg', accent: 'aurora', surface: 'glass', carryOverWeights: true,
  shareExerciseHistory: false, weeklyWorkoutTarget: 4, pinnedExerciseIds: []
};
const normalizePrefs = prefs => {
  prefs.weeklyWorkoutTarget = Math.max(1, Math.min(14, Math.round(+prefs.weeklyWorkoutTarget || 4)));
  if (!Array.isArray(prefs.pinnedExerciseIds)) prefs.pinnedExerciseIds = [];
  prefs.pinnedExerciseIds = [...new Set(prefs.pinnedExerciseIds.filter(id => typeof id === 'string' && id))];
};

// This is the exact object shape emitted by the pre-Capacitor Settings exporter.
const oldPwaExport = JSON.stringify({ state: representativeState, prefs: representativePrefs, theme: 'dark' }, null, 2);
const parsed = backupApi.parseBackup(oldPwaExport);
const cleanNativeStorage = new MemoryStorage({ 'capacitor://unrelated': 'keep-me' });
const nativeReplacement = backupApi.prepareReplacement(parsed, defaultState, defaultPrefs, normalizePrefs);
backupApi.replaceStorage(cleanNativeStorage, nativeReplacement.storageValues);

for (const [key, expected] of Object.entries(nativeReplacement.storageValues)) {
  assert.equal(cleanNativeStorage.getItem(key), expected, `exact restored value for ${key}`);
}
assert.equal(cleanNativeStorage.getItem('capacitor://unrelated'), 'keep-me', 'unrelated native storage is preserved');
assert.deepEqual(JSON.parse(cleanNativeStorage.getItem(backupApi.STORAGE_KEYS.state)).sessions, representativeState.sessions);
assert.deepEqual(JSON.parse(cleanNativeStorage.getItem(backupApi.STORAGE_KEYS.state)).routines, representativeState.routines);
assert.deepEqual(JSON.parse(cleanNativeStorage.getItem(backupApi.STORAGE_KEYS.state)).tempExercises, representativeState.tempExercises);
assert.deepEqual(JSON.parse(cleanNativeStorage.getItem(backupApi.STORAGE_KEYS.prefs)), representativePrefs);

// A native export remains consumable by the same legacy PWA parser and produces identical storage strings.
const nativeExport = JSON.stringify(backupApi.createBackup(nativeReplacement.state, nativeReplacement.prefs, nativeReplacement.theme), null, 2);
const pwaReplacement = backupApi.prepareReplacement(backupApi.parseBackup(nativeExport), defaultState, defaultPrefs, normalizePrefs);
assert.deepEqual(pwaReplacement.storageValues, nativeReplacement.storageValues);

// Malformed and unrelated JSON are rejected before storage changes.
const protectedStorage = new MemoryStorage({ ...nativeReplacement.storageValues, unrelated: 'still-here' });
const beforeMalformed = Object.fromEntries(protectedStorage.values);
assert.throws(() => backupApi.parseBackup('{bad json'), /valid JSON/);
assert.throws(() => backupApi.parseBackup('{"hello":"world"}'), /not a SnowLog backup/);
assert.deepEqual(Object.fromEntries(protectedStorage.values), beforeMalformed);

// A failure during replacement restores every SnowLog key to its exact prior string value.
const previous = {
  [backupApi.STORAGE_KEYS.state]: '{"old":"state"}',
  [backupApi.STORAGE_KEYS.prefs]: '{"old":"prefs"}',
  [backupApi.STORAGE_KEYS.theme]: 'light',
  unrelated: 'still-here'
};
const failingStorage = new MemoryStorage(previous, backupApi.STORAGE_KEYS.prefs);
assert.throws(() => backupApi.replaceStorage(failingStorage, nativeReplacement.storageValues), /simulated storage failure/);
assert.deepEqual(Object.fromEntries(failingStorage.values), previous);

console.log('SnowLog backup compatibility tests passed.');
