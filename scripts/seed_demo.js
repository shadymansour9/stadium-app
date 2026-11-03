#!/usr/bin/env node
/**
 * STADIUM demo data: sample bookings for "Demo Padel Club" and
 * "Demo Tennis Club".
 *
 * The demo venues/courts themselves are defined in lib/main.dart
 * (demoVenues / demoStadiums) and only appear with ?demo=1. This script
 * only creates sample BOOKINGS on those demo courts.
 *
 * Every document it writes has isDemo: true and seededBy: 'seed_demo.js',
 * a fake userId (demo_player_N) and a booking code 0001-0009 (real codes
 * are always 1000-9999, so real players can never join a demo game).
 *
 * Usage (from this folder):
 *   npm install
 *   gcloud auth application-default login       # once; no key files
 *   node seed_demo.js seed      [--dry-run]     # replace seeded bookings with fresh ones (dates relative to today)
 *   node seed_demo.js delete    [--dry-run]     # remove ALL demo bookings on demo courts (seeded + made during demos)
 *   node seed_demo.js list                      # show current demo bookings
 *
 * Safety: only ever touches bookings whose stadiumId is one of the demo
 * court ids below AND isDemo == true. Live football data is never read
 * for writing or deleted.
 */
const admin = require('firebase-admin');

const PROJECT_ID = 'stadium-d5b5f';
const SEED_TAG = 'seed_demo.js';

// Must match demoStadiums in lib/main.dart.
const COURTS = {
  demo_padel_1:  { name: 'PADEL 1',  sport: 'Padel',  pricePerHour: 160, slotMinutes: 90 },
  demo_padel_2:  { name: 'PADEL 2',  sport: 'Padel',  pricePerHour: 160, slotMinutes: 90 },
  demo_padel_3:  { name: 'PADEL 3',  sport: 'Padel',  pricePerHour: 160, slotMinutes: 90 },
  demo_tennis_1: { name: 'TENNIS 1', sport: 'Tennis', pricePerHour: 120, slotMinutes: 60 },
  demo_tennis_2: { name: 'TENNIS 2', sport: 'Tennis', pricePerHour: 120, slotMinutes: 60 },
};
const DEMO_COURT_IDS = Object.keys(COURTS);

const P = (n) => `Demo Player ${n}`;

// [court, daysFromToday, start, playerNumbers, tennisFormat]
// Start times line up with the app's slot grid (padel 90' from 07:00,
// tennis 60' from 07:00).
const SAMPLES = [
  ['demo_padel_1',  1, '17:30', [1, 2, 3, 4]],      // full 4/4
  ['demo_padel_1',  1, '19:00', [5, 6]],            // 2/4 - good to demo "join by code"
  ['demo_padel_2',  1, '20:30', [7, 8, 9]],         // 3/4
  ['demo_padel_3',  2, '19:00', [2]],               // 1/4
  ['demo_padel_2',  3, '08:30', [10, 11, 12, 13]],  // full 4/4
  ['demo_tennis_1', 1, '18:00', [14, 15], 'singles'], // full 2/2
  ['demo_tennis_2', 1, '19:00', [16, 17], 'doubles'], // 2/4
  ['demo_tennis_1', 2, '07:00', [18], 'singles'],     // 1/2
];

// Same format as hebrewWeekday() in lib/main.dart (Dart weekday 1=Mon).
const HE_DAYS = ["ב'", "ג'", "ד'", "ה'", "ו'", "ש'", "א'"];

function addMinutes(hhmm, mins) {
  const [h, m] = hhmm.split(':').map(Number);
  const t = (h * 60 + m + mins) % (24 * 60);
  return `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`;
}

function priceLabel(price, mins) {
  const hours = mins / 60;
  return `₪${price}/${Number.isInteger(hours) ? hours : hours.toFixed(1)}h`;
}

function buildBooking([courtId, dayOffset, start, players, format], index) {
  const court = COURTS[courtId];
  const d = new Date();
  d.setDate(d.getDate() + dayOffset);
  const date = `${d.getDate()}/${d.getMonth() + 1}`;          // app format: d/m
  const dartWeekday = d.getDay() === 0 ? 7 : d.getDay();       // JS 0=Sun -> Dart 7
  const mins = court.slotMinutes;
  const price = Math.round((court.pricePerHour * mins) / 60);
  const maxPlayers = court.sport === 'Padel' ? 4 : (format === 'doubles' ? 4 : 2);
  const names = players.map(P);
  const id = `${courtId}_${date.replace('/', '-')}_${start}`; // same deterministic id as the app
  const data = {
    userId: `demo_player_${players[0]}`,
    userName: names[0],
    phone: '000-0000000',
    stadiumName: court.name,
    stadiumId: courtId,
    day: HE_DAYS[dartWeekday - 1],
    date,
    time: `${start} - ${addMinutes(start, mins)}`,
    price: priceLabel(price, mins),
    priceAmount: price,
    durationMinutes: mins,
    bookingCode: String(index + 1).padStart(4, '0'), // 0001..0008
    players: names,
    createdAt: new Date().toISOString(),
    sport: court.sport,
    maxPlayers,
    ...(court.sport === 'Tennis' ? { format } : {}),
    bookingType: court.sport === 'Padel' ? 'מגרש פאדל' : 'מגרש טניס',
    bookingTypeEn: `${court.sport} court`,
    bookingTypeIcon: 'tennis',
    bookingTypeColor: 'green',
    isDemo: true,
    seededBy: SEED_TAG,
  };
  return { id, data };
}

function isDemoCourtDoc(doc) {
  const d = doc.data();
  return d.isDemo === true && DEMO_COURT_IDS.includes(d.stadiumId);
}

async function demoDocs(db) {
  const snap = await db.collection('bookings').where('isDemo', '==', true).get();
  return snap.docs.filter(isDemoCourtDoc);
}

async function commitInBatches(db, ops) {
  for (let i = 0; i < ops.length; i += 400) {
    const batch = db.batch();
    ops.slice(i, i + 400).forEach((op) => op(batch));
    await batch.commit();
  }
}

async function main() {
  const [cmd, ...flags] = process.argv.slice(2);
  const dryRun = flags.includes('--dry-run');
  if (!['seed', 'delete', 'list'].includes(cmd)) {
    console.log('Usage: node seed_demo.js <seed|delete|list> [--dry-run]');
    process.exit(1);
  }

  admin.initializeApp({ credential: admin.credential.applicationDefault(), projectId: PROJECT_ID });
  const db = admin.firestore();
  console.log(`Project: ${PROJECT_ID}${dryRun ? '  (DRY RUN - nothing will be written)' : ''}`);

  const existing = await demoDocs(db);

  if (cmd === 'list') {
    existing.forEach((d) => {
      const b = d.data();
      console.log(`  ${d.id}  ${b.stadiumName}  ${b.date} ${b.time}  ${b.players.length}/${b.maxPlayers}  code=${b.bookingCode}  ${b.seededBy ? 'seeded' : 'made during demo'}`);
    });
    console.log(`${existing.length} demo booking(s).`);
    return;
  }

  if (cmd === 'delete') {
    console.log(`Deleting ${existing.length} demo booking(s) on demo courts:`);
    existing.forEach((d) => console.log(`  - ${d.id}`));
    if (!dryRun) await commitInBatches(db, existing.map((d) => (b) => b.delete(d.ref)));
    console.log(dryRun ? 'Dry run: nothing deleted.' : 'Done.');
    return;
  }

  // seed: replace previously seeded docs (keeps bookings made during demos).
  const oldSeeded = existing.filter((d) => d.data().seededBy === SEED_TAG);
  const fresh = SAMPLES.map(buildBooking);
  console.log(`Removing ${oldSeeded.length} previously seeded booking(s), writing ${fresh.length} new:`);
  fresh.forEach(({ id, data }) =>
    console.log(`  + ${id}  ${data.players.length}/${data.maxPlayers}  code=${data.bookingCode}`));
  if (!dryRun) {
    await commitInBatches(db, [
      ...oldSeeded.map((d) => (b) => b.delete(d.ref)),
      ...fresh.map(({ id, data }) => (b) => b.set(db.collection('bookings').doc(id), data)),
    ]);
  }
  console.log(dryRun ? 'Dry run: nothing written.' : 'Done.');
}

main().catch((e) => {
  console.error(e.message || e);
  if (String(e.message || e).includes('default credentials')) {
    console.error('\nRun:  gcloud auth application-default login');
  }
  process.exit(1);
});
