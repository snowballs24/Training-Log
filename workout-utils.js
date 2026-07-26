(function (root) {
  'use strict';

  function localDateISO(value = new Date()) {
    const date = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(date.getTime())) return '';
    return [
      String(date.getFullYear()).padStart(4, '0'),
      String(date.getMonth() + 1).padStart(2, '0'),
      String(date.getDate()).padStart(2, '0')
    ].join('-');
  }

  function isCompletedSet(set) {
    return Number(set?.reps) > 0;
  }

  function completedSets(sets) {
    return (Array.isArray(sets) ? sets : []).filter(isCompletedSet);
  }

  function completedExerciseItems(items) {
    return (Array.isArray(items) ? items : []).filter(
      item => completedSets(item?.sets ?? item?.performed).length > 0
    );
  }

  const api = Object.freeze({
    localDateISO,
    isCompletedSet,
    completedSets,
    completedExerciseItems
  });

  root.SnowLogWorkout = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
