// ESM builtin parity: every enumerable key of a builtin's CommonJS object is
// also an ESM named export, and every ESM export exists on the object.
//
// Prints nothing when the two surfaces agree; the golden file is empty. A line
// like `MISSING node:stream.getDefaultHighWaterMark` means esm.d's table has
// fallen behind js/prelude (add the name to the module's list in
// src/djs/modules/esm.d).
const mods = [
    'assert', 'assert/strict', 'buffer', 'child_process', 'cluster', 'crypto',
    'async_hooks', 'console', 'dgram', 'diagnostics_channel', 'dns', 'dns/promises', 'events', 'fs',
    'fs/promises', 'http', 'http2', 'https', 'module', 'net', 'os', 'path',
    'path/posix', 'path/win32',
    'perf_hooks', 'process', 'querystring', 'readline', 'readline/promises',
    'stream', 'stream/consumers', 'stream/promises', 'stream/web',
    'string_decoder', 'timers', 'timers/promises', 'tls', 'trace_events',
    'tty', 'url', 'util', 'util/types', 'v8', 'vm', 'worker_threads', 'zlib',
];

let bad = 0;
for (const name of mods) {
    const cjs = require('node:' + name);
    const ns = await import('node:' + name);
    const cjsKeys = Object.keys(cjs).filter((k) => k !== 'default');
    const esmKeys = Object.keys(ns).filter((k) => k !== 'default');
    for (const k of cjsKeys) {
        if (esmKeys.indexOf(k) < 0) {
            console.log('MISSING node:' + name + '.' + k);
            bad++;
        }
    }
    for (const k of esmKeys) {
        if (!(k in cjs)) {
            console.log('EXTRA node:' + name + '.' + k);
            bad++;
        }
    }
}
if (bad > 0) {
    console.log(bad + ' mismatch(es)');
    process.exitCode = 1;
}
