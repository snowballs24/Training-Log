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
  const group = name => data.muscle.find(m => m.name === name);
  assert(data.muscle.map(m => m.name).join() === 'Chest,Back,Shoulders,Biceps,Triceps,Quads,Hamstrings,Glutes,Calves,Core', 'Muscle group list failed');
  assert(group('Quads').direct === 1 && group('Calves').direct === 1 && group('Glutes').assist === 0.5 && group('Quads').daysSince === 3, 'Squat and calf credit failed');
  assert(group('Chest').direct === 1 && group('Chest').average === 0.5 && group('Chest').daysSince === 0, 'Muscle balance baseline failed');
  assert(group('Triceps').direct === 0 && group('Triceps').assist === 0.5 && group('Shoulders').assist === 0.5 && group('Triceps').daysSince === 0, 'Bench press should give half credit to triceps and shoulders');
  assert(group('Back').direct === 1 && group('Back').average === 0.3 && group('Biceps').assist === 0.5 && group('Biceps').average === 0.1 && group('Back').daysSince === 5, 'Row baseline and biceps assistance failed');
  assert(data.unmappedSets === 0, 'Every exercise in this history should be mapped');
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

// ---- Exercise → muscle mapping: every built-in exercise must be recognised ----
{
  const c = makeContext();
  const libStart = html.indexOf('const EX_LIB = {'), libEnd = html.indexOf('};', libStart);
  const EX_LIB = vm.runInNewContext('(' + html.slice(libStart + 'const EX_LIB = '.length, libEnd + 1) + ')');
  const validMuscles = vm.runInContext('DASHBOARD_MUSCLES', c);
  assert(validMuscles.length === 11, 'Muscle list was not read');
  const primary = (name, category) => {
    const muscles = c.dashboardExerciseMuscles({ name, category });
    assert(muscles, `No muscle mapping for "${name}"`);
    for (const [muscle, weight] of Object.entries(muscles)) {
      assert(validMuscles.includes(muscle) && (weight === 1 || weight === 0.5), `Invalid mapping for "${name}"`);
    }
    const main = Object.keys(muscles).filter(m => muscles[m] === 1);
    assert(main.length >= 1, `"${name}" has no primary muscle`);
    return main;
  };
  const allowed = {
    'Chest': ['Chest'], 'Back': ['Back', 'Glutes'], 'Shoulders': ['Shoulders'], 'Legs – Squat': ['Quads'],
    'Legs – Hinge': ['Hamstrings', 'Glutes', 'Back'], 'Quads/Hams': ['Quads', 'Hamstrings'], 'Glutes': ['Glutes'],
    'Biceps': ['Biceps'], 'Triceps': ['Triceps'], 'Calves': ['Calves'], 'Core': ['Core'], 'Other/Machine': ['Back', 'Shoulders']
  };
  let checked = 0;
  for (const [category, names] of Object.entries(EX_LIB)) for (const name of names) {
    const main = primary(name, category);
    assert(main.every(m => allowed[category].includes(m)), `"${name}" (${category}) mapped to ${main.join('/')}`);
    checked++;
  }
  assert(checked > 90, 'Exercise library was not read');
  // Every exercise named in a routine template must be recognised from its name alone.
  const templateNames = new Set();
  for (const block of html.slice(0, libStart).matchAll(/ex:\s*\[([\s\S]*?)\]/g)) for (const s of block[1].matchAll(/['"]([^'"\n]+)['"]/g)) templateNames.add(s[1]);
  assert(templateNames.size > 30, 'Routine templates were not read');
  for (const name of templateNames) primary(name, '');

  const muscles = (name, category = '') => JSON.stringify(c.dashboardExerciseMuscles({ name, category }));
  const expectMuscles = (name, expected, category) => assert(muscles(name, category) === JSON.stringify(expected), `"${name}" mapped to ${muscles(name, category)}`);
  expectMuscles('Barbell Bench Press', { Chest: 1, Triceps: 0.5, Shoulders: 0.5 });
  expectMuscles('Chest-Supported Row', { Back: 1, Biceps: 0.5 });
  expectMuscles('Wide-Grip Pulldown', { Back: 1, Biceps: 0.5 });
  expectMuscles('Straight-Arm Pulldown', { Back: 1 });
  expectMuscles('Overhead Triceps Extension', { Triceps: 1 });
  expectMuscles('Overhead Press', { Shoulders: 1, Triceps: 0.5 });
  expectMuscles('Seated Leg Curl', { Hamstrings: 1 });
  expectMuscles('Incline DB Curl', { Biceps: 1 });
  expectMuscles('Leg Press Calf Raise', { Calves: 1 });
  expectMuscles('Hanging Leg Raise', { Core: 1 });
  expectMuscles('Cable Lateral Raise', { Shoulders: 1 });
  expectMuscles('Back Squat', { Quads: 1, Glutes: 0.5 });
  expectMuscles('Back Extension', { Back: 1, Glutes: 0.5, Hamstrings: 0.5 });
  expectMuscles('Romanian Deadlift', { Hamstrings: 1, Glutes: 0.5, Back: 0.5 });
  expectMuscles('Hip Thrust', { Glutes: 1, Hamstrings: 0.5 });
  expectMuscles('Cable Kickback', { Glutes: 1, Hamstrings: 0.5 }, 'Glutes');
  expectMuscles('Triceps Kickback', { Triceps: 1 });
  expectMuscles('Dip', { Triceps: 1, Chest: 0.5, Shoulders: 0.5 }, 'Triceps');
  expectMuscles('Dips (Chest)', { Chest: 1, Triceps: 0.5, Shoulders: 0.5 }, 'Chest');
  expectMuscles('Rear Delt Flye', { Shoulders: 1, Back: 0.5 });
  expectMuscles('Hammer Curl', { Biceps: 1, Forearms: 0.5 });
  // Custom exercises: an unrecognised name uses its chosen category; a true unknown is left out.
  expectMuscles('Ben Special', { Triceps: 1 }, 'Triceps');
  expectMuscles('Mystery Machine', { Quads: 1, Glutes: 0.5 }, 'Legs – Squat');
  assert(c.dashboardExerciseMuscles({ name: 'Treadmill Walk', category: 'Other/Machine' }) === null, 'Unknown exercises must not be guessed');
  assert(c.dashboardExerciseMuscles(undefined) === null && c.dashboardExerciseMuscles({}) === null, 'Missing exercise handling failed');

  // Unmatched sets are reported rather than silently dropped.
  c.state.exerciseNames = { walk: 'Treadmill Walk' };
  c.state.sessions = [session('2026-07-20', 'd', 'r', 'walk', 0, 10)];
  assert(c.calculateDashboardData(now).unmappedSets === 1, 'Unmatched set count failed');
}

console.log('Dashboard calculation tests passed.');
