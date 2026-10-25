// Assorted prelude regressions: structuredClone __proto__ handling, the
// legacy Stream constructor keeping pipe(), and cpSync copying symlinks
// as symlinks.
const fs = require('fs');
const path = require('path');
const stream = require('stream');
const os = require('os');

// 1. structuredClone must not rewrite the clone's prototype through an own
// "__proto__" key (JSON.parse can produce one).
const parsed = JSON.parse('{"__proto__": {"x": 1}, "a": 2}');
const clone = structuredClone(parsed);
const protoKeys = Object.keys(Object.getPrototypeOf(clone));
console.log('proto-clean', protoKeys.length === 0 || protoKeys.indexOf('x') < 0);
console.log('own-a', clone.a === 2);

// 2. The legacy Stream constructor exposes pipe (a second hoisted
// declaration used to drop it from the prototype).
console.log('stream-pipe', typeof stream.Stream.prototype.pipe === 'function');
const s = new stream.Stream();
console.log('instance-pipe', typeof s.pipe === 'function');

// 3. cpSync copies a symlink as a symlink (dereference off by default).
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'djs-cp-'));
try {
    fs.writeFileSync(path.join(dir, 'real.txt'), 'content');
    fs.symlinkSync('real.txt', path.join(dir, 'link.txt'));
    fs.cpSync(path.join(dir, 'link.txt'), path.join(dir, 'copy.txt'));
    const st = fs.lstatSync(path.join(dir, 'copy.txt'));
    console.log('cp-symlink', st.isSymbolicLink());
    console.log('cp-target', fs.readFileSync(path.join(dir, 'copy.txt'), 'utf8'));

    // dereference copies the target's content instead.
    fs.cpSync(path.join(dir, 'link.txt'), path.join(dir, 'deref.txt'), { dereference: true });
    const st2 = fs.lstatSync(path.join(dir, 'deref.txt'));
    console.log('cp-deref', !st2.isSymbolicLink());
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
console.log('done');
