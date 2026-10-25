// Module sources read through readFileAlloc must not be silently truncated
// when fstat cannot be trusted (FIFOs, procfs, files that grow). The growth
// loop used to be dead code, truncating at ~8 KiB and reporting success.
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

// The module loader is confined to this test's project root (tests/js —
// no package.json above it), so the fixture lives next to the test.
const here = path.dirname(path.resolve(process.argv[1]));
const name = 'fifo-mod-' + process.pid;
const dir = path.join(here, name);
fs.mkdirSync(dir, { recursive: true });
const fifo = path.join(dir, 'bigmod.js');
spawnSync('mkfifo', [fifo]);

// 40 KB of module source, far past the old truncation point.
const payload = 'module.exports = "' + 'x'.repeat(40000) + '";\n';
const src = path.join(dir, 'payload.js');
fs.writeFileSync(src, payload);

// The writer blocks opening the FIFO until the reader (require) connects.
const w = spawn('sh', ['-c', 'cat "$1" > "$2"', 'sh', src, fifo]);
w.on('exit', function () { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) {} });

const m = require('./' + name + '/bigmod.js');
console.log('module-len', m.length);
console.log('matches', m === 'x'.repeat(40000));

// Janitor: if this process is killed mid-run the FIFO would outlive the
// test (and hang any later `grep -R` over tests/), so force-remove it
// regardless of the writer's fate.
setTimeout(function () {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) {}
}, 3000).unref();
