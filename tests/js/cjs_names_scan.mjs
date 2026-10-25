// Static imports of every name the scanner should find in
// cjs_names_scan_lib.cjs; a name the scanner misses fails this module at
// link time, so the golden doubles as the assertion.
import { simple, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13,
         defined, defined2, afterRegex, getter, tail } from './cjs_names_scan_lib.cjs';

// quoted-key/another-quoted are not valid identifiers, so they are checked
// through the namespace object instead.
import * as ns from './cjs_names_scan_lib.cjs';

console.log('count', [simple, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, afterRegex, getter, tail].length);
console.log('values', simple === 1, a13 === 13, tail === 20);
console.log('quoted', ns['quoted-key'] === 14, ns['another-quoted'] === 15);
console.log('defined', ns.defined === 16, ns.defined2 === 17);
console.log('decoys-absent', !('decoy' in ns), !('regexDecoy' in ns),
            !('fakeFromStr' in ns), !('fake2' in ns), !('compared' in ns));
console.log('ns-total', Object.keys(ns).length);
