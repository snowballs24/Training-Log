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
      log: { prepared: {}, notes: {}, isActive: false }, uiDashboardChoice: null
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
  assert(!data.next.day && !data.streak.hasHistory, 'New-user guidance state failed');
}

{
  const c = makeContext();
  c.state.routines = [{ id: 'r1', name: 'PPL', days: [{ id: 'push', name: 'Push', exercises: [{ id: 'bench', name: 'Bench Press', category: 'Chest – Press' }] }] }];
  c.state.activeRoutineId = 'r1';
  const data = c.calculateDashboardData(now);
  assert(data.next.day.id === 'push' && !data.next.lastCompleted, 'Routine-without-history suggestion failed');
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
  assert(data.next.day.id === 'b', 'Routine rotation failed');
}

{
  const c = makeContext();
  c.state.routines = [{ id: 'r', name: 'R', days: [{ id: 'd', name: 'D', exercises: [{ id: 'bench', name: 'Bench Press' }] }] }];
  c.state.activeRoutineId = 'r';
  c.state.sessions = [session('2026-07-19', 'd', 'r', 'bench', '', '')];
  c.prefs.pinnedExerciseIds = ['bench'];
  c.state.log.isActive = true;
  const data = c.calculateDashboardData(now);
  assert(data.next.active, 'Active workout resume state failed');
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

console.log('Dashboard calculation tests passed.');
