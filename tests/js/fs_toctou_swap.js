// Async-fs check-to-open TOCTOU: the permission check captures the
// canonical path's inode identity on the JS thread; the threadpool worker
// verifies the fd it actually opened. Swapping the leaf between check and
// open must fail closed with EACCES instead of reading the swapped file.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, spawnSync } = require('child_process');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'djs-toctou-'));
const target = path.join(dir, 'target.txt');
const decoy = path.join(dir, 'decoy.txt');
fs.writeFileSync(target, 'REAL');
fs.writeFileSync(decoy, 'DECOY');

// 1. Occupy every threadpool worker: each readFile blocks in open() on a
//    FIFO with no writer yet. The runtime sets a larger default than libuv's
//    four, so size the blockade from the effective setting.
const poolSize = Math.max(1, Number(process.env.UV_THREADPOOL_SIZE) || 4);
const fifos = [];
for (let i = 0; i < poolSize; i++) {
    const f = path.join(dir, 'f' + i + '.fifo');
    spawnSync('mkfifo', [f]);
    fifos.push(f);
    fs.readFile(f, function () {});
}

// 2. Queue the read under attack: no worker is free, so its open() has not
//    run. The permission check (and identity capture) already happened.
let settled = false;
fs.readFile(target, function (err, data) {
    settled = true;
    console.log('swapped-read', err ? err.code : data.toString());
    console.log('done');
    // The scratch directory is left for the OS temp cleaner: removing the
    // FIFOs here could unlink them while a blocked worker is still in
    // open(), which would pin a threadpool request forever.
});

// 3. Swap the leaf for a different inode while the request is queued.
fs.renameSync(decoy, target);

// 4. Release the blocked workers; the queued read now opens the swapped
//    leaf and must reject it (identity mismatch -> EACCES). Exit listeners
//    keep the spawned writers from holding the loop open.
for (const f of fifos) {
    const w = spawn('sh', ['-c', 'printf released > "$1"', 'sh', f]);
    w.on('exit', function () {});
}

// Watchdog: the swap verdict must arrive.
setTimeout(function () {
    if (!settled) {
        console.log('swapped-read pending (bad)');
        fs.rmSync(dir, { recursive: true, force: true });
    }
}, 2000).unref();
