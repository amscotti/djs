// Crypto parameter validation: cipher key/IV lengths must match the
// cipher's requirements before OpenSSL reads them, and the uninterruptible
// CPU paths (pbkdf2, key generation) are parameter-bounded.
const crypto = require('crypto');

// The Cipher class defers to native on update(); that is where the lengths
// are validated.
// 1. Short key: must throw, not read past the buffer inside OpenSSL.
// (Cipher buffers updates; the native call — and the length check —
// happens in final().)
try {
    const c = crypto.createCipheriv('aes-128-cbc', Buffer.alloc(5), Buffer.alloc(16));
    c.update('hello');
    c.final();
    console.log('short-key no-throw (bad)');
} catch (e) {
    console.log('short-key', e.constructor.name);
}

// 2. Short IV.
try {
    const c = crypto.createCipheriv('aes-128-cbc', Buffer.alloc(16), Buffer.alloc(2));
    c.update('hello');
    c.final();
    console.log('short-iv no-throw (bad)');
} catch (e) {
    console.log('short-iv', e.constructor.name);
}

// 3. Correct sizes still work end to end.
const key = crypto.randomBytes(16);
const iv = crypto.randomBytes(16);
const c = crypto.createCipheriv('aes-128-cbc', key, iv);
const enc = Buffer.concat([c.update('hello'), c.final()]);
const d = crypto.createDecipheriv('aes-128-cbc', key, iv);
const pt = Buffer.concat([d.update(enc), d.final()]);
console.log('cbc-ok', pt.toString() === 'hello');

// 4. GCM round trip still works (caller-chosen IV length).
const gkey = crypto.randomBytes(32);
const giv = crypto.randomBytes(12);
const g = crypto.createCipheriv('aes-256-gcm', gkey, giv);
const gc = Buffer.concat([g.update('secret'), g.final()]);
const tag = g.getAuthTag();
const gd = crypto.createDecipheriv('aes-256-gcm', gkey, giv);
gd.setAuthTag(tag);
const gpt = Buffer.concat([gd.update(gc), gd.final()]);
console.log('gcm-ok', gpt.toString() === 'secret');

// 5. pbkdf2 and keygen parameter bounds.
try {
    crypto.pbkdf2Sync('p', 's', 20000001, 32, 'sha256');
    console.log('pbkdf2 no-throw (bad)');
} catch (e) {
    console.log('pbkdf2-bound', e.constructor.name);
}
console.log('pbkdf2-ok', crypto.pbkdf2Sync('p', 's', 1000, 32, 'sha256').length);
try {
    crypto.generateKeyPairSync('rsa', { modulusLength: 1 << 30 });
    console.log('keygen no-throw (bad)');
} catch (e) {
    console.log('keygen-bound', e.constructor.name);
}
