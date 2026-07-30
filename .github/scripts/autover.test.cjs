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

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
