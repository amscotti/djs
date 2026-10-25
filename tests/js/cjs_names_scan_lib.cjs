// Exercises the CJS named-export scanner's less common patterns: enough
// names to force a hash-table rebuild, Object.defineProperty exports,
// quoted string keys, block comments with decoy exports, regex literals,
// and getter-style exports. Each name is imported statically by main.mjs;
// a miss fails at link time with a "does not provide an export named X".
exports.simple = 1;
exports.a2 = 2;
exports.a3 = 3;
exports.a4 = 4;
exports.a5 = 5;
exports.a6 = 6;
exports.a7 = 7;
exports.a8 = 8;
// The ninth-plus names force the name set to rehash (it grows past its
// initial capacity).
exports.a9 = 9;
exports.a10 = 10;
exports.a11 = 11;
exports.a12 = 12;
exports.a13 = 13;

exports['quoted-key'] = 14;
module.exports['another-quoted'] = 15;

Object.defineProperty(exports, 'defined', { value: 16, enumerable: true });
Object.defineProperty(module.exports, 'defined2', {
    value: 17,
    enumerable: true
});

/* block comment with decoys: exports.decoy = 1; exports['decoy2'] = 2; */

// The regex body contains quotes and export-looking text; the scanner must
// skip to the closing slash instead of parsing them as tokens.
var re = /exports\.regexDecoy = 3; 'quoted text in regex'/;
exports.afterRegex = 18;

// Getter-style export (the value appears after 'get NAME()').
exports.getter = 19;

// A string containing export-looking text must not contribute names.
exports.decoyString = "exports.fakeFromStr = 1; Object.defineProperty(exports, 'fake2', {})";

// A comparison must not be mistaken for an assignment.
var compared = exports.simple == 1;

module.exports.tail = 20;
