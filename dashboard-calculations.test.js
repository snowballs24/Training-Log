const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync('index.html', 'utf8');
const start = html.indexOf('function dashboardDate(');
const end = html.indexOf('function renderPinnedExerciseSettings(', start);
if (start < 0 || end < 0) throw new Error('Dashboard calculation layer not found');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function exerciseCategory(name) {
  const n = String(name || '').toLowerCase();
  if (n.includes('bench')) return 'Chest – Press';
  if (n.includes('row')) return 'Back – Row';
  if (n.includes('squat')) return 'Legs – Squat';
  return 'Other/Machine';
}

function makeContext() {
  const context = {
    state: {
      routines: [], sessions: [], activeRoutineId: null, exerciseNames: {},
      log: { prepared: {}, notes: {}, isActive: false }
    },
    prefs: { weeklyWorkoutTarget: 4, pinnedExerciseIds: [], units: 'kg' },
    activeRoutine() { return context.state.routines.find(r => r.id === context.state.activeRoutineId) || null; },
    guessCategory: exerciseCategory,
    epley1RM(w, r) { w = +w || 0; r = +r || 0; return w > 0 && r > 0 ? Math.round(w * (1 + r / 30)) : 0; },
    draftHasData() { return false; },
    console
  };
  vm.createContext(context);
  vm.runInContext(html.slice(start, end), context);
  return context;
}

function session(date, dayId, routineId, exerciseId, weight = 100, reps = 5) {
  return {
    id: `${date}-${dayId}-${exerciseId}`, workoutDate: date, dateISO: `${date}T10:00:00.000Z`,
    dayId, routineId, exerciseId, sets: [{ set: 1, weight, reps }],
    totalVolume: Math.round(weight * reps)
  };
}

const now = new Date(2026, 6, 20, 12); // Monday, local time.

{
  const c = makeContext();
  const data = c.calculateDashboardData(now);
  assert(data.weekly.workouts === 0 && data.recent.length === 0, 'New-user empty state failed');
  assert(!data.streak.hasHistory, 'New-user guidance state failed');
}

{
  const c = makeContext();
  c.state.routines = [{ id: 'r1', name: 'PPL', days: [{ id: 'push', name: 'Push', exercises: [{ id: 'bench', name: 'Bench Press', category: 'Chest – Press' }] }] }];
  c.state.activeRoutineId = 'r1';
  const data = c.calculateDashboardData(now);
  assert(data.weekly.workouts === 0, 'Routine-without-history state failed');
}

{
  const c = makeContext();
  c.prefs.weeklyWorkoutTarget = 2;
  c.state.routines = [{ id: 'r1', name: 'Full Body', days: [
    { id: 'a', name: 'A', exercises: [{ id: 'bench', name: 'Bench Press', category: 'Chest – Press' }] },
    { id: 'b', name: 'B', exercises: [{ id: 'row', name: 'Barbell Row', category: 'Back – Row' }] }
  ] }];
  c.state.activeRoutineId = 'r1';
  c.state.sessions = [
    session('2026-07-07', 'a', 'r1', 'bench', 90, 5),
    session('2026-07-10', 'b', 'r1', 'row', 70, 8),
    session('2026-07-14', 'a', 'r1', 'bench', 95, 5),
    session('2026-07-17', 'b', 'r1', 'row', 72.5, 8),
    session('2026-07-20', 'a', 'r1', 'bench', 100, 5)
  ];
  c.prefs.pinnedExerciseIds = ['bench', 'row'];
  const data = c.calculateDashboardData(now);
  assert(data.weekly.workouts === 1 && data.weekly.target === 2 && data.streak.needed === 1, 'Weekly target calculation failed');
  assert(data.streak.current === 2 && data.streak.longest === 2, 'In-progress-week streak handling failed');
  assert(data.pinned[0].current === 117 && data.pinned[0].change > 0, 'Estimated 1RM calculation failed');
  assert(data.recent.length === 3, 'Recent workout limit failed');
  assert(data.muscleGroups.Chest > 0 && data.muscleGroups.Back > 0, 'Muscle distribution failed');
}

{
  const c = makeContext();
  c.state.routines = [{ id: 'r', name: 'R', days: [{ id: 'd', name: 'D', exercises: [{ id: 'bench', name: 'Bench Press' }] }] }];
  c.state.activeRoutineId = 'r';
  c.state.sessions = [session('2026-07-19', 'd', 'r', 'bench', '', '')];
  c.prefs.pinnedExerciseIds = ['bench'];
  const data = c.calculateDashboardData(now);
  assert(data.pinned[0].current === 0 && !data.pinned[0].hasHistory, 'Missing weight/reps handling failed');
}

{
  const c = makeContext();
  c.prefs.weeklyWorkoutTarget = 1;
  c.state.routines = [{ id: 'r', name: 'R', days: [{ id: 'd', name: 'D', exercises: [{ id: 'row', name: 'Barbell Row' }] }] }];
  c.state.activeRoutineId = 'r';
  c.state.sessions = [
    session('2026-06-23', 'd', 'r', 'row'),
    session('2026-06-30', 'd', 'r', 'row'),
    session('2026-07-14', 'd', 'r', 'row')
  ];
  const data = c.calculateDashboardData(now);
  assert(data.streak.current === 1, 'Current streak after an earlier gap failed');
  assert(data.streak.longest === 2, 'Longest recorded streak failed');
}

// ---- Redesigned dashboard: next session, load, heatmap, records, balance ----
{
  const c = makeContext();
  c.state.routines = [{ id: 'r', name: 'PPL', days: [
    { id: 'push', name: 'Push', exercises: [{ id: 'bench', name: 'Bench Press', category: 'Chest' }] },
    { id: 'pull', name: 'Pull', exercises: [{ id: 'row', name: 'Barbell Row', category: 'Back' }] },
    { id: 'legs', name: 'Legs', exercises: [{ id: 'squat', name: 'Back Squat', category: 'Legs – Squat' }, { id: 'calf', name: 'Calf Raise', category: 'Calves' }] }
  ] }];
  c.state.activeRoutineId = 'r';
  let data = c.calculateDashboardData(now);
  assert(data.next.suggestedDayId === 'push' && !data.next.resume, 'First session should be the first routine day');
  assert(data.strength.length === 0 && data.strengthAuto, 'Empty strength state failed');
  assert(data.heat.weeks.length === 17 && data.heat.weeks.every(w => w.days.length === 7), 'Heatmap shape failed');
  assert(data.load.length === 8 && data.load[7].current, 'Training-load window failed');

  c.state.sessions = [
    session('2026-07-06', 'push', 'r', 'bench', 90, 5),
    session('2026-07-08', 'pull', 'r', 'row', 70, 8),
    session('2026-07-13', 'push', 'r', 'bench', 95, 5),
    session('2026-07-15', 'pull', 'r', 'row', 70, 8),
    session('2026-07-17', 'legs', 'r', 'squat', 120, 5),
    session('2026-07-17', 'legs', 'r', 'calf', 60, 12),
    session('2026-07-20', 'push', 'r', 'bench', 100, 5)
  ];
  data = c.calculateDashboardData(now);
  assert(data.next.suggestedDayId === 'pull', 'Rotation should continue after the last completed day');
  assert(data.next.trainedToday && data.weekly.trainedToday, 'Trained-today flag failed');
  assert(data.next.days[2].daysSince === 3 && data.next.days[2].exerciseCount === 2, 'Per-day recency failed');
  assert(data.weekly.days.length === 7 && data.weekly.days[0].trained && data.weekly.days[0].isToday && data.weekly.days[1].isFuture, 'Week strip failed');
  assert(data.weekly.daysLeft === 6, 'Days-left calculation failed');
  assert(data.weekly.prevWorkouts === 1 && data.weekly.prevVolume === 475, 'Same-point-last-week comparison failed');
  assert(data.load[7].volume === 500 && data.load[6].workouts === 3 && data.load[6].sets === 4, 'Weekly load totals failed');
  assert(data.heat.workouts === 6 && data.heat.weeks[16].days[0].level === 2 && data.heat.weeks[15].days[4].level === 4, 'Heatmap intensity failed');
  assert(data.prs.length === 1 && data.prs[0].exerciseId === 'bench' && data.prs[0].iso === '2026-07-20' && data.prs[0].gain === 6, 'Latest record per exercise failed');
  assert(data.recent[0].hasPR && data.recent[0].prCount === 1, 'Session record badge failed');
  assert(data.strengthAuto && data.strength[0].id === 'bench' && data.strength[0].series.join() === '105,111,117', 'Automatic key-lift selection failed');
  assert(data.strength[0].lastSet.weight === 100 && data.strength[0].recentPB, 'Key-lift detail failed');
  const legs = data.muscle.find(m => m.name === 'Legs'), chest = data.muscle.find(m => m.name === 'Chest');
  assert(legs.sets === 2 && legs.daysSince === 3, 'Calves and squats should both count towards legs');
  assert(chest.sets === 1 && chest.average === 0.5 && chest.daysSince === 0, 'Muscle balance baseline failed');
  assert(data.totals.workouts === 6 && data.totals.sets === 7 && data.totals.firstIso === '2026-07-06', 'Lifetime totals failed');

  c.prefs.pinnedExerciseIds = ['row'];
  data = c.calculateDashboardData(now);
  assert(!data.strengthAuto && data.strength.length === 1 && data.strength[0].id === 'row', 'Pinned lifts should override automatic selection');

  // An unsaved draft is surfaced for resuming on its own day and is never altered.
  c.state.log.dayId = 'legs';
  c.state.log.prepared = { squat: [{ set: 1, weight: 120, reps: '5' }] };
  const before = JSON.stringify(c.state);
  data = c.calculateDashboardData(now);
  assert(data.next.resume && data.next.suggestedDayId === 'legs' && data.next.days[2].drafted === 1, 'Draft resume state failed');
  assert(JSON.stringify(c.state) === before, 'Dashboard calculations must not mutate stored data');
}

{
  // Malformed history must never break the dashboard.
  const c = makeContext();
  c.state.sessions = [null, 'x', { workoutDate: 'not-a-date' }, { workoutDate: '2026-07-19', exerciseId: 'gone', sets: null }, { dateISO: '2026-07-18T09:00:00.000Z', exerciseId: 'gone', sets: [{ weight: 'abc', reps: -3 }] }];
  const data = c.calculateDashboardData(now);
  assert(data.totals.workouts === 2 && data.totals.sets === 0 && data.strength.length === 0 && data.next === null, 'Malformed history handling failed');
}

console.log('Dashboard calculation tests passed.');
