// Auto Version — resolves the next App Store version string from App Store Connect.
//
// Rule (mirrors src/version-bump.mjs resolvePlatformTarget so the workflow and the
// submit tool always agree on which version the binary belongs to):
//   look at EVERY appStoreVersion across iOS + macOS, take the numerically highest.
//   that version still open for a new build  -> reuse it        (1.0.4 -> 1.0.4)
//   that version finished / live             -> bump last part  (1.0.3 -> 1.0.4)
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

/**
 * @param {{versionString:string, state:string, platform:string}[]} versions
 * @returns {{version:string, reused:boolean, basedOn:string}}
 */
function resolveVersion(versions) {
  if (!versions.length) throw new Error('no versions');
  let max = versions[0].versionString;
  for (const v of versions) if (cmpVersion(v.versionString, max) > 0) max = v.versionString;

  const atMax = versions.filter(v => cmpVersion(v.versionString, max) === 0);
  // Prefer reuse when in doubt: bumping past an open version would upload a build
  // that the submit tool can never attach (it targets the open version).
  const anyOpen = atMax.some(v => !CREATE_NEXT.has(v.state));

  return anyOpen
    ? { version: max, reused: true, basedOn: max }
    : { version: bumpVersion(max), reused: false, basedOn: max };
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
  const app = apps.data[0];

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
      });
    }
  }
  return { appId: app.id, appName: app.attributes && app.attributes.name, versions: out };
}

// --- main ---

async function main() {
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
    console.log('  ' + v.platform.padEnd(7) + ' ' + v.versionString.padEnd(10) + ' ' + v.state);
  }

  const r = resolveVersion(info.versions);
  console.log(
    r.reused
      ? 'Highest is ' + r.basedOn + ' and it is still open for a build → reusing it.'
      : 'Highest is ' + r.basedOn + ' and it is finished → next is ' + r.version + '.'
  );
  emit(r.version, r.reused ? 'reused open version ' + r.basedOn : 'bumped from ' + r.basedOn);
}

if (process.env.AUTOVER_SELFTEST) {
  module.exports = { cmpVersion, bumpVersion, resolveVersion, CREATE_NEXT };
} else {
  main().catch((e) => {
    console.log('::error::Auto Version crashed: ' + (e && e.stack ? e.stack : e));
    process.exit(1);
  });
}
