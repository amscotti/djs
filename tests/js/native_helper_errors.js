// Native helper error arms reachable from JS:
// - value.d throwInternalError body: exhaust the zlib stream table
// - value.d toStringView failure: an object whose string conversion throws
//   reaches the native converter (dgram.bind host argument)
const assert = require('assert');
const zlib = require('zlib');
const dgram = require('dgram');

// 1. The zlib table is capped at 32 concurrent streams; the 33rd create is
//    an internal error, not a crash.
let leaked = 0;
try {
    for (let i = 0; i < 40; i++) {
        zlib.createDeflate();
        leaked += 1;
    }
    console.log('zlib-exhaust no-throw (bad)');
} catch (e) {
    console.log('zlib-exhaust', e.constructor.name, leaked === 32);
}

// 2. A throwing toString in a native argument surfaces as the pending
//   exception, not a silent wrong-type error.
const s = dgram.createSocket('udp4');
try {
    s.bind(0, { toString: function () { throw new Error('nope'); } });
    console.log('throwing-host no-throw (bad)');
} catch (e) {
    console.log('throwing-host', e.message === 'nope');
}
try { s.close(); } catch (e) {}
console.log('done');
