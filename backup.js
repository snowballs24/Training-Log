(function (root) {
  'use strict';

  const STORAGE_KEYS = Object.freeze({
    state: 'workout_logger_mobile_v13_themeOnly',
    prefs: 'workout_prefs_v13',
    theme: 'workout_theme'
  });
  const PERSISTED_STATE_KEYS = Object.freeze([
    'routines', 'activeRoutineId', 'sessions', 'uiPrevWeeks', 'uiPrevWeeksAll',
    'uiOpen', 'log', 'trendsDayId', 'uiTrendsCollapsed', 'tempExercises', 'exerciseNames'
  ]);

  const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const cloneJson = value => JSON.parse(JSON.stringify(value));

  function rejectUnsafeKeys(value) {
    if (!value || typeof value !== 'object') return;
    for (const key of Object.keys(value)) {
      if (key === '__proto__' || key === 'prototype' || key === 'constructor') {
        throw new Error('The SnowLog backup contains an unsafe field.');
      }
      rejectUnsafeKeys(value[key]);
    }
  }

  function validateWorkoutData(state) {
    if (!Array.isArray(state.routines) || !state.routines.every(isRecord)) {
      throw new Error('The SnowLog routines are invalid.');
    }
    for (const routine of state.routines) {
      if (routine.days !== undefined && (!Array.isArray(routine.days) || !routine.days.every(isRecord))) {
        throw new Error('The SnowLog routine days are invalid.');
      }
      for (const day of routine.days || []) {
        if (day.exercises !== undefined && (!Array.isArray(day.exercises) || !day.exercises.every(isRecord))) {
          throw new Error('The SnowLog exercises are invalid.');
        }
      }
    }
    if (!Array.isArray(state.sessions) || !state.sessions.every(isRecord)) {
      throw new Error('The SnowLog workout history is invalid.');
    }
    for (const session of state.sessions) {
      if (session.sets !== undefined && (!Array.isArray(session.sets) || !session.sets.every(isRecord))) {
        throw new Error('The SnowLog workout sets are invalid.');
      }
    }
    if (!isRecord(state.log)) throw new Error('The SnowLog active workout is invalid.');
    for (const key of ['prepared', 'notes', 'exerciseContexts']) {
      if (state.log[key] !== undefined && !isRecord(state.log[key])) {
        throw new Error('The SnowLog active workout is invalid.');
      }
    }
    for (const key of ['uiPrevWeeks', 'uiOpen', 'tempExercises', 'exerciseNames']) {
      if (state[key] !== undefined && !isRecord(state[key])) {
        throw new Error('The SnowLog saved data is invalid.');
      }
    }
  }

  function validatePreferences(prefs) {
    if (prefs.pinnedExerciseIds !== undefined &&
        (!Array.isArray(prefs.pinnedExerciseIds) || !prefs.pinnedExerciseIds.every(id => typeof id === 'string'))) {
      throw new Error('The SnowLog pinned exercises setting is invalid.');
    }
    if (prefs.units !== undefined && prefs.units !== 'kg' && prefs.units !== 'lb') {
      throw new Error('The SnowLog weight setting is invalid.');
    }
  }

  function validateBackup(value) {
    if (!isRecord(value) || !isRecord(value.state) || !isRecord(value.prefs)) {
      throw new Error('This is not a SnowLog backup.');
    }
    rejectUnsafeKeys(value);
    validateWorkoutData(value.state);
    validatePreferences(value.prefs);
    if (value.theme !== 'dark' && value.theme !== 'light') {
      throw new Error('The SnowLog theme is invalid.');
    }
    return cloneJson({ state: value.state, prefs: value.prefs, theme: value.theme });
  }

  function parseBackup(text) {
    if (typeof text !== 'string' || !text.trim()) throw new Error('The selected backup is empty.');
    let value;
    try { value = JSON.parse(text); }
    catch { throw new Error('The selected file is not valid JSON.'); }
    return validateBackup(value);
  }

  function createBackup(state, prefs, theme) {
    return validateBackup({ state, prefs, theme });
  }

  function persistedState(state) {
    const result = {};
    for (const key of PERSISTED_STATE_KEYS) result[key] = state[key];
    return result;
  }

  function prepareReplacement(backup, currentState, currentPrefs, normalizePrefs) {
    const valid = validateBackup(backup);
    const nextState = Object.assign(cloneJson(currentState), valid.state);
    const nextPrefs = Object.assign(cloneJson(currentPrefs), valid.prefs);
    if (typeof normalizePrefs === 'function') normalizePrefs(nextPrefs);
    return {
      state: nextState,
      prefs: nextPrefs,
      theme: valid.theme,
      storageValues: {
        [STORAGE_KEYS.state]: JSON.stringify(persistedState(nextState)),
        [STORAGE_KEYS.prefs]: JSON.stringify(nextPrefs),
        [STORAGE_KEYS.theme]: valid.theme
      }
    };
  }

  function snapshot(storage) {
    const values = {};
    for (const key of Object.values(STORAGE_KEYS)) values[key] = storage.getItem(key);
    return values;
  }

  function restoreSnapshot(storage, values) {
    for (const key of Object.values(STORAGE_KEYS)) {
      if (values[key] === null) storage.removeItem(key);
      else storage.setItem(key, values[key]);
    }
  }

  function replaceStorage(storage, storageValues) {
    const recovery = snapshot(storage);
    try {
      for (const key of Object.values(STORAGE_KEYS)) storage.setItem(key, storageValues[key]);
    } catch (error) {
      try { restoreSnapshot(storage, recovery); }
      catch { throw new Error('Import failed and SnowLog could not restore the recovery snapshot.'); }
      throw error;
    }
    return recovery;
  }

  root.SnowLogBackup = Object.freeze({
    STORAGE_KEYS, PERSISTED_STATE_KEYS, createBackup, parseBackup, prepareReplacement,
    replaceStorage, restoreSnapshot, persistedState, validateBackup
  });
  if (typeof module !== 'undefined' && module.exports) module.exports = root.SnowLogBackup;
})(typeof globalThis !== 'undefined' ? globalThis : window);
