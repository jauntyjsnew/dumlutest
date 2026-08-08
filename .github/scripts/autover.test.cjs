process.env.AUTOVER_SELFTEST = '1';
const { cmpVersion, bumpVersion, resolveVersion } = require('./autover.cjs');

let pass = 0, fail = 0;
function eq(actual, expected, label) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) { pass++; console.log('  ok   ' + label); }
  else { fail++; console.log('  FAIL ' + label + '\n         got      ' + JSON.stringify(actual) + '\n         expected ' + JSON.stringify(expected)); }
}
const V = (versionString, state, platform) => ({ versionString, state, platform });

console.log('cmpVersion');
eq(cmpVersion('1.0.10', '1.0.9') > 0, true, '1.0.10 > 1.0.9  (numeric, not lexical)');
eq(cmpVersion('1.0.2', '1.0.10') < 0, true, '1.0.2 < 1.0.10');
eq(cmpVersion('1.1', '1.0.9') > 0, true, '1.1 > 1.0.9');
eq(cmpVersion('2.0', '1.9.9') > 0, true, '2.0 > 1.9.9');
eq(cmpVersion('1.0', '1.0.0'), 0, '1.0 == 1.0.0');
eq(cmpVersion('1.0.3', '1.0.3'), 0, 'equal');

console.log('bumpVersion');
eq(bumpVersion('1.0.4'), '1.0.5', '1.0.4 -> 1.0.5');
eq(bumpVersion('1.0.9'), '1.0.10', '1.0.9 -> 1.0.10  (not 1.1.0)');
eq(bumpVersion('1.2'), '1.3', '1.2 -> 1.3');
eq(bumpVersion('1.0.0'), '1.0.1', '1.0.0 -> 1.0.1');

console.log('resolveVersion — the case the user described');
eq(
  resolveVersion([V('1.0.4', 'READY_FOR_SALE', 'IOS'), V('1.0.2', 'READY_FOR_SALE', 'MAC_OS')]),
  { version: '1.0.5', reused: false, basedOn: '1.0.4' },
  'iOS 1.0.4 live + Mac 1.0.2 live -> 1.0.5 (highest across BOTH platforms, +1)'
);

console.log('resolveVersion — the trap: an open version must be reused, never skipped');
eq(
  resolveVersion([V('1.0.4', 'PREPARE_FOR_SUBMISSION', 'IOS'), V('1.0.3', 'READY_FOR_SALE', 'IOS')]),
  { version: '1.0.4', reused: true, basedOn: '1.0.4' },
  'iOS 1.0.4 PREPARE -> reuse 1.0.4 (bumping would orphan the binary)'
);
eq(
  resolveVersion([V('1.0.4', 'REJECTED', 'IOS'), V('1.0.3', 'READY_FOR_SALE', 'IOS')]),
  { version: '1.0.4', reused: true, basedOn: '1.0.4' },
  'Apple rejected 1.0.4 -> resubmit the SAME 1.0.4'
);
eq(
  resolveVersion([V('1.0.4', 'METADATA_REJECTED', 'IOS')]),
  { version: '1.0.4', reused: true, basedOn: '1.0.4' },
  'METADATA_REJECTED -> reuse'
);
eq(
  resolveVersion([V('1.0.4', 'INVALID_BINARY', 'IOS')]),
  { version: '1.0.4', reused: true, basedOn: '1.0.4' },
  'INVALID_BINARY -> reuse'
);
eq(
  resolveVersion([V('1.0.4', 'DEVELOPER_REJECTED', 'IOS')]),
  { version: '1.0.5', reused: false, basedOn: '1.0.4' },
  'DEVELOPER_REJECTED -> next  (matches the submit tool CREATE_NEXT set)'
);

console.log('resolveVersion — same version on both platforms, different states');
eq(
  resolveVersion([V('1.0.4', 'READY_FOR_SALE', 'IOS'), V('1.0.4', 'PREPARE_FOR_SUBMISSION', 'MAC_OS')]),
  { version: '1.0.4', reused: true, basedOn: '1.0.4' },
  'iOS live but Mac still open at 1.0.4 -> reuse 1.0.4 (Mac would otherwise be orphaned)'
);
eq(
  resolveVersion([V('1.0.4', 'READY_FOR_SALE', 'IOS'), V('1.0.4', 'READY_FOR_SALE', 'MAC_OS')]),
  { version: '1.0.5', reused: false, basedOn: '1.0.4' },
  'both live at 1.0.4 -> 1.0.5'
);

console.log('resolveVersion — misc');
eq(
  resolveVersion([V('1.0.9', 'READY_FOR_SALE', 'IOS'), V('1.0.10', 'READY_FOR_SALE', 'MAC_OS')]),
  { version: '1.0.11', reused: false, basedOn: '1.0.10' },
  'Mac 1.0.10 beats iOS 1.0.9 numerically -> 1.0.11'
);
eq(
  resolveVersion([V('1.0', 'READY_FOR_SALE', 'IOS')]),
  { version: '1.1', reused: false, basedOn: '1.0' },
  'two-component version 1.0 -> 1.1'
);
eq(
  resolveVersion([V('1.0.0', 'PREPARE_FOR_SUBMISSION', 'IOS')]),
  { version: '1.0.0', reused: true, basedOn: '1.0.0' },
  'brand-new app, first version open -> 1.0.0'
);

// ── Numbers spent by an uploaded build whose version record was deleted ──────
// Field failure 2026-08-08 (olmconverter, run 31257834668): App Store Connect
// listed 1.0.0-1.0.4 and the live store showed 1.0.4, so this resolved to 1.0.5
// — and Apple rejected the upload with "must be higher than the previously
// approved version [1.0.6]". 1.0.5 and 1.0.6 had been created, approved and then
// deleted, which removes them from appStoreVersions but not from Apple's memory.
// fetchVersions now also reads preReleaseVersions (the train every uploaded
// binary leaves behind, which survives that deletion) and feeds those in as
// spent. These cases pin the resolver behaviour that fix depends on.
const B = (versionString, platform) =>
  ({ versionString, state: 'REPLACED_WITH_NEW_VERSION', platform, source: 'build' });

console.log('resolveVersion — versions spent by an uploaded build');
eq(
  resolveVersion([
    V('1.0.4', 'READY_FOR_SALE', 'IOS'), V('1.0.4', 'READY_FOR_SALE', 'MAC_OS'),
    B('1.0.5', 'IOS'), B('1.0.6', 'IOS'),
  ]),
  { version: '1.0.7', reused: false, basedOn: '1.0.6' },
  'the exact field failure: store tops out at 1.0.4, builds claimed 1.0.5+1.0.6 -> 1.0.7'
);
eq(
  resolveVersion([
    V('1.0.5', 'PREPARE_FOR_SUBMISSION', 'IOS'), B('1.0.5', 'IOS'),
  ]),
  { version: '1.0.5', reused: true, basedOn: '1.0.5' },
  'normal flow is untouched: a build uploaded to an OPEN version still reuses it'
);
eq(
  resolveVersion([
    V('1.0.5', 'REJECTED', 'IOS'), B('1.0.5', 'IOS'), B('1.0.5', 'MAC_OS'),
  ]),
  { version: '1.0.5', reused: true, basedOn: '1.0.5' },
  'a rejected version with builds against it is still open -> reuse, do not skip'
);
eq(
  resolveVersion([V('1.0.4', 'READY_FOR_SALE', 'IOS'), B('1.0.2', 'IOS')]),
  { version: '1.0.5', reused: false, basedOn: '1.0.4' },
  'older build trains never drag the answer down'
);

// ── fetchVersions against a stubbed App Store Connect ────────────────────────
// Covers what the pure resolver cannot: which rows get collected, that the app
// is matched by EXACT bundle id, and that a missing preReleaseVersions endpoint
// degrades to the old behaviour instead of failing the build.
const { fetchVersions } = require('./autover.cjs');

// A throwaway P-256 key — makeToken signs with it, nothing here talks to Apple.
const testPem = require('node:crypto')
  .generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  .privateKey.export({ type: 'pkcs8', format: 'pem' });

function stubFetch(routes) {
  const calls = [];
  global.fetch = async (url) => {
    calls.push(url);
    for (const [needle, body] of routes) {
      if (url.includes(needle)) {
        if (body === 'ERROR') return { ok: false, status: 503, text: async () => 'maintenance' };
        return { ok: true, status: 200, text: async () => JSON.stringify(body) };
      }
    }
    return { ok: true, status: 200, text: async () => JSON.stringify({ data: [] }) };
  };
  return calls;
}
const appRow = (id, bundleId) => ({ id, attributes: { bundleId, name: 'App ' + id } });
const storeRow = (versionString, appStoreState) => ({ attributes: { versionString, appStoreState } });
const trainRow = (version, platform) => ({ attributes: { version, platform } });

(async () => {
  console.log('fetchVersions — collection and safety');

  // The field failure, end to end: store list stops at 1.0.4, trains hold 1.0.6.
  stubFetch([
    ['/v1/apps?filter', { data: [appRow('111', 'tools.rush.olmconverter.olm')] }],
    ['appStoreVersions?filter[platform]=IOS', { data: [storeRow('1.0.4', 'READY_FOR_SALE')] }],
    ['appStoreVersions?filter[platform]=MAC_OS', { data: [storeRow('1.0.4', 'READY_FOR_SALE')] }],
    ['preReleaseVersions', { data: [trainRow('1.0.5', 'IOS'), trainRow('1.0.6', 'IOS')] }],
  ]);
  let info = await fetchVersions('tools.rush.olmconverter.olm', 'K', 'I', testPem);
  eq(
    resolveVersion(info.versions),
    { version: '1.0.7', reused: false, basedOn: '1.0.6' },
    'deleted 1.0.5/1.0.6 recovered from build trains -> 1.0.7, not the rejected 1.0.5'
  );

  // filter[bundleId] is a loose filter: a sibling app must never be picked.
  stubFetch([
    ['/v1/apps?filter', { data: [
      appRow('222', 'tools.rush.olmconverter.olmviewer'),
      appRow('111', 'tools.rush.olmconverter.olm'),
    ] }],
    ['appStoreVersions?filter[platform]=IOS', { data: [storeRow('3.0.0', 'READY_FOR_SALE')] }],
    ['preReleaseVersions', { data: [] }],
  ]);
  info = await fetchVersions('tools.rush.olmconverter.olm', 'K', 'I', testPem);
  eq(info.appId, '111', 'exact bundle id wins over a sibling returned first by the filter');

  // No exact match at all must stop the run, never guess an app.
  stubFetch([['/v1/apps?filter', { data: [appRow('999', 'tools.rush.somethingelse')] }]]);
  let threw = '';
  try { await fetchVersions('tools.rush.olmconverter.olm', 'K', 'I', testPem); }
  catch (e) { threw = e.message; }
  eq(threw.includes('no app exactly matches'), true, 'no exact bundle-id match throws instead of using data[0]');

  // preReleaseVersions unavailable -> behave exactly as before, do not fail.
  stubFetch([
    ['/v1/apps?filter', { data: [appRow('111', 'tools.rush.olmconverter.olm')] }],
    ['appStoreVersions?filter[platform]=IOS', { data: [storeRow('1.0.4', 'READY_FOR_SALE')] }],
    ['preReleaseVersions', 'ERROR'],
  ]);
  info = await fetchVersions('tools.rush.olmconverter.olm', 'K', 'I', testPem);
  eq(
    resolveVersion(info.versions),
    { version: '1.0.5', reused: false, basedOn: '1.0.4' },
    'train endpoint down -> falls back to the old store-only answer, run survives'
  );

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
