// utf16le encoding/decoding and case-insensitive encoding names.
const b1 = Buffer.from('hi', 'utf16le');
console.log('len', b1.length);
console.log('bytes', b1[0], b1[1], b1[2], b1[3]);

// Surrogate pair (U+1F600) round trip.
const b2 = Buffer.from('\u{1F600}', 'utf16le');
console.log('astral-len', b2.length);
console.log('astral-rt', b2.toString('utf16le') === '\u{1F600}');

// Unpaired surrogate decodes to U+FFFD, not garbage.
const b3 = Buffer.from([0x3d, 0xd8]);
console.log('unpaired', b3.toString('utf16le') === '\uFFFD');

// ucs2 alias and case-insensitive names.
console.log('alias', Buffer.from('A', 'ucs2').length === 2);
console.log('upper', Buffer.from('A', 'UTF-16LE').length === 2);

// isEncoding no longer advertises what native cannot do.
console.log('isenc', Buffer.isEncoding('utf16le'), Buffer.isEncoding('UTF8'), Buffer.isEncoding('nope'));
