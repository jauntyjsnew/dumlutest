// Auto Version — resolves the next App Store version string from App Store Connect.
//
// Rule (mirrors src/version-bump.mjs resolvePlatformTarget so the workflow and the
// submit tool always agree on which version the binary belongs to):
//   look at EVERY appStoreVersion across iOS + macOS, take the numerically highest.
//   that version still open for a new build  -> reuse it        (1.0.4 -> 1.0.4)
//   that version finished / live             -> bump last part  (1.0.3 -> 1.0.4)
//
// ⛔ "Still open" is a PER-PLATFORM question, and the run only has to satisfy the
//    platforms it actually uploads to (TARGET_PLATFORM). Asking "is ANY row at the
//    max still open" mixes the two tracks, and Apple does not: a version that is
//    live on one platform is CLOSED for new binaries on that platform, whatever
//    the other platform's record says.
//    MEASURED (PstViewer, zomtest run 31784610686, target all_devices):
//      IOS    6.0.6  READY_FOR_SALE   ← closed
//      MAC_OS 6.0.6  REJECTED         ← open, and it is what answered "yes"
//    so this script reused 6.0.6, and twelve minutes later altool refused the iOS
//    leg twice over — 90062 "must contain a higher version than the previously
//    approved version [6.0.6]" and 90186 "train version '6.0.6' is closed for new
//    build submissions". Nothing on the read side learned anything, so every
//    re-dispatch repeated it.
//
// Zero dependencies: ES256 JWT is signed with node:crypto, ASC is called with global fetch.

const crypto = require('node:crypto');
const fs = require('node:fs');

// States meaning "this version is done, open the next one". Everything else
// (PREPARE_FOR_SUBMISSION, REJECTED, METADATA_REJECTED, INVALID_BINARY, IN_REVIEW, ...)
// means the slot is still open, so we reuse it.
const CREATE_NEXT = new Set([
  'READY_FOR_SALE',
  'DEVELOPER_REJECTED',
  'REPLACED_WITH_NEW_VERSION',
]);

/** Numeric component-wise compare: "1.0.10" > "1.0.9". */
function cmpVersion(a, b) {
  const A = String(a).split('.');
  const B = String(b).split('.');
  const n = Math.max(A.length, B.length);
  for (let i = 0; i < n; i++) {
    const d = (parseInt(A[i], 10) || 0) - (parseInt(B[i], 10) || 0);
    if (d !== 0) return d;
  }
  return 0;
}

/** "1.0.4" -> "1.0.5", "1.2" -> "1.3". */
function bumpVersion(v) {
  const parts = String(v).split('.');
  const n = parseInt(parts[parts.length - 1], 10);
  if (Number.isNaN(n)) return String(v) + '.1';
  parts[parts.length - 1] = String(n + 1);
  return parts.join('.');
}

const ASC_PLATFORMS = new Set(['IOS', 'MAC_OS']);

/** Which App Store platforms a run actually uploads to, from the workflow's
 *  `target_platform` input. Anything unrecognised means both — the safe reading,
 *  since a platform we forget to check is a platform Apple can refuse. */
function platformsFor(target) {
  switch (String(target || '').trim()) {
    case 'macos_only': return ['MAC_OS'];
    case 'iphone_and_ipad':
    case 'iphone_only':
    case 'ipad_only': return ['IOS'];
    default: return ['IOS', 'MAC_OS'];
  }
}

/**
 * @param {{versionString:string, state:string, platform:string}[]} versions
 * @param {string[]} [platforms] ASC platforms this run will upload to
 * @returns {{version:string, reused:boolean, basedOn:string, closedOn:string[]}}
 */
function resolveVersion(versions, platforms) {
  if (!versions.length) throw new Error('no versions');
  const targets = platforms && platforms.length ? platforms : ['IOS', 'MAC_OS'];

  let max = versions[0].versionString;
  for (const v of versions) if (cmpVersion(v.versionString, max) > 0) max = v.versionString;

  const atMax = versions.filter(v => cmpVersion(v.versionString, max) === 0);

  // A platform is CLOSED at this version when its own APP STORE VERSION RECORD
  // there is finished — live, replaced, or developer-rejected. That is the state
  // Apple checks when it closes a train.
  //
  // ⛔ Only `source: 'store'` rows can close a platform. A pre-release row is a
  //    TestFlight train, and a train does NOT close a version: uploading build 2
  //    of the same marketing version is ordinary. Those rows exist here to stop
  //    the MAX from being understated (a version record can be deleted, the train
  //    cannot) — letting them also close a platform would undo the very rule the
  //    2026-08-08 fix was careful to preserve, and start skipping open versions.
  const closedOn = targets.filter(p => atMax.some(v =>
    v.source !== 'build' &&
    (v.platform === p || !ASC_PLATFORMS.has(v.platform)) &&
    CREATE_NEXT.has(v.state)
  ));

  // Prefer reuse when in doubt: bumping past an open version would upload a build
  // that the submit tool can never attach (it targets the open version). But that
  // preference only applies where reuse is POSSIBLE — a closed train refuses the
  // upload outright, and a build nobody can attach still beats a build that does
  // not exist.
  const reusable = closedOn.length === 0 && atMax.some(v => !CREATE_NEXT.has(v.state));

  return reusable
    ? { version: max, reused: true, basedOn: max, closedOn: [] }
    : { version: bumpVersion(max), reused: false, basedOn: max, closedOn };
}

// --- App Store Connect ---

function makeToken(keyId, issuerId, privateKeyPem) {
  const now = Math.floor(Date.now() / 1000);
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const header = enc({ alg: 'ES256', kid: keyId, typ: 'JWT' });
  const payload = enc({ iss: issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' });
  const signature = crypto
    .createSign('SHA256')
    .update(header + '.' + payload)
    .sign({ key: privateKeyPem, dsaEncoding: 'ieee-p1363' })
    .toString('base64url');
  return header + '.' + payload + '.' + signature;
}

async function asc(path, token) {
  const res = await fetch('https://api.appstoreconnect.apple.com' + path, {
    headers: { Authorization: 'Bearer ' + token },
  });
  const body = await res.text();
  if (!res.ok) throw new Error('ASC ' + res.status + ' on ' + path + ' :: ' + body.slice(0, 400));
  return JSON.parse(body);
}

async function fetchVersions(bundleId, keyId, issuerId, privateKeyPem) {
  const token = makeToken(keyId, issuerId, privateKeyPem);

  const apps = await asc('/v1/apps?filter[bundleId]=' + encodeURIComponent(bundleId) + '&limit=10', token);
  if (!apps.data || apps.data.length === 0) {
    throw new Error('App Store Connect has no app with bundle id "' + bundleId + '".');
  }
  // filter[bundleId] is not an exact-equality filter, so more than one app can come
  // back. Taking data[0] blind would resolve the version of a DIFFERENT app and
  // stamp this binary with it — unrecoverable once uploaded. Demand the exact id.
  const app = apps.data.find(a => a.attributes && a.attributes.bundleId === bundleId);
  if (!app) {
    const seen = apps.data.map(a => (a.attributes && a.attributes.bundleId) || a.id).join(', ');
    throw new Error(
      'no app exactly matches bundle id "' + bundleId + '" (the filter returned: ' + seen + ').'
    );
  }

  const out = [];
  for (const platform of ['IOS', 'MAC_OS']) {
    const res = await asc(
      '/v1/apps/' + app.id + '/appStoreVersions?filter[platform]=' + platform +
      '&fields[appStoreVersions]=versionString,platform,appStoreState,appVersionState&limit=200',
      token
    );
    for (const v of res.data || []) {
      out.push({
        versionString: v.attributes.versionString,
        state: v.attributes.appStoreState || v.attributes.appVersionState || 'UNKNOWN',
        platform,
        source: 'store',
      });
    }
  }

  // ⛔ appStoreVersions is NOT the whole truth about which version numbers are
  // spent. Delete a version record in App Store Connect and it vanishes from this
  // list — but Apple's upload service still refuses anything at or below it
  // ("CFBundleShortVersionString [1.0.5] must be higher than the previously
  // approved version [1.0.6]", error 90062). That is a 12-minute build thrown away
  // at the very last step, and it repeats on every run because nothing on the
  // read side ever learns about 1.0.6.
  //
  // preReleaseVersions is the missing source: every binary ever uploaded leaves a
  // train here carrying its marketing version, and these survive the deletion of
  // the App Store version record. Merged in as spent, so the resolver bumps past
  // them.
  //
  // Marking them spent does NOT break the "reuse an open version" rule: resolve
  // asks whether ANY entry at the max is still open, so a real open appStoreVersion
  // at the same number still wins and is reused. And a train with no version record
  // is precisely the case the reuse rule does not cover — there is no open record
  // for the submit tool to target, so stepping over it cannot cause the silent
  // mismatch that rule exists to prevent.
  try {
    const pre = await asc(
      '/v1/apps/' + app.id + '/preReleaseVersions' +
      '?fields[preReleaseVersions]=version,platform&limit=200',
      token
    );
    for (const v of pre.data || []) {
      const vs = v.attributes && v.attributes.version;
      if (!vs) continue;
      out.push({
        versionString: vs,
        state: 'REPLACED_WITH_NEW_VERSION', // spent — never reuse a number a build already claimed
        platform: (v.attributes && v.attributes.platform) || 'UNKNOWN',
        source: 'build',
      });
    }
  } catch (e) {
    // Additive safety net only. If this endpoint is unavailable the run must behave
    // exactly as it did before, not die — the store list alone is still correct for
    // every app whose version records were never deleted.
    console.log('::warning::Could not read uploaded-build versions (' + e.message +
      '); falling back to App Store version records only.');
  }

  return { appId: app.id, appName: app.attributes && app.attributes.name, versions: out };
}

// --- main ---

async function main() {
  // Runs before actions/setup-node in some workflows, so it uses whatever Node the
  // runner image ships. Say so plainly rather than dying on "fetch is not defined".
  if (typeof fetch !== 'function') {
    console.log('::error::Auto Version needs Node 18 or newer (global fetch); this runner has ' + process.version + '.');
    process.exit(1);
  }

  const bundleId = (process.env.BUNDLE_ID || '').trim();
  const manual = (process.env.MANUAL_VERSION || '').trim();
  const publish = (process.env.BUILD_MODE || '').trim() === 'publish_to_appstore';

  const emit = (version, source) => {
    if (process.env.GITHUB_OUTPUT) {
      fs.appendFileSync(process.env.GITHUB_OUTPUT, 'version=' + version + '\n');
      fs.appendFileSync(process.env.GITHUB_OUTPUT, 'source=' + source + '\n');
    }
    console.log('==> version=' + version + '  (source: ' + source + ')');
  };

  if (manual) {
    console.log('Manual version supplied — skipping the App Store Connect lookup.');
    emit(manual, 'manual override');
    return;
  }

  // A wrong version number on an uploaded binary cannot be taken back, so when we
  // are actually publishing every failure below is fatal rather than a guess.
  const fail = (msg) => {
    if (publish) {
      console.log('::error::Auto Version failed: ' + msg);
      console.log('::error::Re-run with the "version" input filled in to override.');
      process.exit(1);
    }
    console.log('::warning::Auto Version failed (' + msg + ') — build_only, falling back to 1.0.0.');
    emit('1.0.0', 'fallback (build_only, ASC unreachable)');
  };

  if (!bundleId) return fail('bundle id is empty — the app config could not be read.');

  const keyId = (process.env.ASC_KEY_ID || '').trim();
  const issuerId = (process.env.ASC_ISSUER_ID || '').trim();
  const keyB64 = (process.env.ASC_KEY_B64 || '').trim();
  if (!keyId || !issuerId || !keyB64) return fail('App Store Connect API key is missing from the secret.');

  let info;
  try {
    info = await fetchVersions(bundleId, keyId, issuerId, Buffer.from(keyB64, 'base64').toString('utf8'));
  } catch (e) {
    return fail(e.message);
  }

  if (!info.versions.length) return fail('the app exists but has no versions yet — create the first version in App Store Connect.');

  console.log('App: ' + (info.appName || '?') + '  (' + bundleId + ')');
  console.log('Versions in App Store Connect:');
  for (const v of [...info.versions].sort((a, b) => cmpVersion(b.versionString, a.versionString))) {
    // Say which list each row came from. When a number is spent only because a
    // build once claimed it, that is the whole explanation for the bump — and
    // without it the log looks like it invented a version out of nowhere.
    const origin = v.source === 'build' ? '  (uploaded build, no version record)' : '';
    console.log('  ' + v.platform.padEnd(7) + ' ' + v.versionString.padEnd(10) + ' ' + v.state + origin);
  }

  const targets = platformsFor(process.env.TARGET_PLATFORM);
  console.log('Uploading to: ' + targets.join(' + ') +
    '  (target_platform=' + (process.env.TARGET_PLATFORM || 'unset → both') + ')');

  const r = resolveVersion(info.versions, targets);
  if (r.closedOn && r.closedOn.length) {
    // Name the platform that forced the bump, and the record left behind. Without
    // this the log reads as if the script skipped an open version for no reason —
    // and the open record IS a real loose end somebody has to close by hand.
    const stillOpen = info.versions.filter(v =>
      cmpVersion(v.versionString, r.basedOn) === 0 && !CREATE_NEXT.has(v.state));
    console.log('Highest is ' + r.basedOn + ', but it is CLOSED on ' + r.closedOn.join(' + ') +
      ' → Apple would refuse this upload (90062/90186). Next is ' + r.version + '.');
    for (const v of stillOpen) {
      console.log('::warning::' + v.platform + ' still has an open ' + v.versionString +
        ' record (' + v.state + '). This build goes to ' + r.version +
        ', so update or delete that record in App Store Connect.');
    }
  } else {
    console.log(
      r.reused
        ? 'Highest is ' + r.basedOn + ' and it is still open for a build → reusing it.'
        : 'Highest is ' + r.basedOn + ' and it is finished → next is ' + r.version + '.'
    );
  }
  emit(r.version, r.reused ? 'reused open version ' + r.basedOn : 'bumped from ' + r.basedOn);
}

if (process.env.AUTOVER_SELFTEST) {
  // fetchVersions is exported so the test can drive it against a stubbed fetch.
  // The version-picking rules are pure and easy to test, but the part that
  // actually broke in the field was which ROWS reach them — that has to be
  // covered too, not just eyeballed.
  module.exports = { cmpVersion, bumpVersion, resolveVersion, platformsFor, CREATE_NEXT, fetchVersions };
} else {
  main().catch((e) => {
    console.log('::error::Auto Version crashed: ' + (e && e.stack ? e.stack : e));
    process.exit(1);
  });
}
