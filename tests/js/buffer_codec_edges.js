// Codec edge coverage: native argument validation (via __djs, since the
// prelude's Buffer.from pre-validates), unknown encodings, partial hex
// input, uppercase hex digits, and the utf16le decode output arms for
// 1-byte (ASCII) and 2-byte (U+0080..U+07FF) code points.
const B = Buffer;

function t(label, fn) {
    try { fn(); console.log(label, 'no-throw'); }
    catch (e) { console.log(label, e.name, e.message.slice(0, 24)); }
}

// 1. Native entry-point validation (the documented __djs surface).
t('encode-non-string', function () { __djs.bytes.encode(42, 'hex'); });
t('encode-non-string-enc', function () { __djs.bytes.encode('a', 7); });
t('encode-bad-enc', function () { __djs.bytes.encode('a', 'utf7'); });
t('decode-bad-enc', function () { __djs.bytes.decode(B.from('aa', 'hex'), 'utf7'); });
t('decode-non-view', function () { __djs.bytes.decode('nope', 'hex'); });

// 2. Uppercase hex digits are valid in both directions.
const up = B.from('4AEF', 'hex');
console.log('hex-upper', up[0], up[1], up.toString('hex') === '4aef');

// 3. Invalid hex stops at the bad pair (lenient, like Node).
console.log('hex-partial', B.from('4aZZ', 'hex').length);
// Odd-length hex: the dangling nibble is dropped.
console.log('hex-odd', B.from('4a4', 'hex').length);

// 4. utf16le decode output arms:
// 'h' -> U+0068 (< 0x80, 1 UTF-8 byte), U+00E9 -> 2 bytes, U+20AC -> 3.
const s1 = B.from([0x68, 0x00]).toString('utf16le');
const s2 = B.from([0xe9, 0x00]).toString('utf16le');
const s3 = B.from([0xac, 0x20]).toString('utf16le');
console.log('u16-1b', s1 === 'h', Buffer.byteLength(s1, 'utf8'));
console.log('u16-2b', s2 === 'é', Buffer.byteLength(s2, 'utf8'));
console.log('u16-3b', s3 === '\u20AC', Buffer.byteLength(s3, 'utf8'));
// Odd trailing byte is dropped (incomplete unit).
console.log('u16-odd-tail', B.from([0x68, 0x00, 0x68]).toString('utf16le') === 'h');
// Lone LOW surrogate halves each become U+FFFD.
console.log('u16-low-surr', B.from([0x00, 0xdc, 0x00, 0xdc]).toString('utf16le') === '\uFFFD\uFFFD');
// Truncated pair: high surrogate with a low half missing at the buffer end.
console.log('u16-trunc-pair', B.from([0x3d, 0xd8]).toString('utf16le') === '\uFFFD');
