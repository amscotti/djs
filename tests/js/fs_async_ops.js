// The async (callback) fs surface: stat/readdir/unlink/rename/realpath and
// their error delivery. The sync variants dominate the suite; these arms
// were entirely dark under coverage. Every step owns its files so callback
// interleaving cannot change what another step observes, and results are
// printed in declaration order (completion order races between the
// threadpool workers).
const fs = require('fs');
const path = require('path');
const os = require('os');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'djs-async-'));
const order = [];
const lines = {};
let done = 0;

function record(name) {
    order.push(name);
    return function (text) {
        done += 1;
        lines[name] = text;
    };
}

function ok(rec, name, fn) {
    return function (err) {
        if (err) { rec(name + ' unexpected-err ' + err.code); return; }
        try { fn.apply(null, [rec].concat(Array.prototype.slice.call(arguments, 1))); }
        catch (e) { rec(name + ' throw ' + (e.code || e.message)); }
    };
}
function fail(rec, name, fn) {
    return function (e) {
        if (!e) { rec(name + ' no-err (bad)'); return; }
        try { fn(rec, e); } catch (x) { rec(name + ' throw ' + x.message); }
    };
}

// --- stat ------------------------------------------------------------
const statDir = path.join(root, 'stat');
fs.mkdirSync(statDir);
fs.writeFileSync(path.join(statDir, 'a.txt'), 'x');
fs.stat(path.join(statDir, 'a.txt'), ok(record('stat'), 'stat', function (r, st) {
    r('stat ' + st.isFile() + ' ' + (st.size === 1));
}));
fs.stat(path.join(statDir, 'nope'), fail(record('stat-missing'), 'stat-missing', function (r, e) {
    r('stat-missing ' + e.code);
}));
fs.readdir(statDir, ok(record('readdir'), 'readdir', function (r, names) {
    r('readdir ' + (names.length === 1) + ' ' + (names[0] === 'a.txt'));
}));
fs.readdir(path.join(statDir, 'nope'), fail(record('readdir-missing'), 'readdir-missing', function (r, e) {
    r('readdir-missing ' + e.code);
}));
fs.readdir(statDir, { withFileTypes: true }, ok(record('readdir-dirent'), 'readdir-dirent', function (r, ents) {
    const e = ents[0];
    r('readdir-dirent ' + !!e + ' ' + (e && e.name === 'a.txt') + ' ' + (e && e.isFile()));
}));

// --- realpath ----------------------------------------------------------
const rpDir = path.join(root, 'rp');
fs.mkdirSync(rpDir);
fs.writeFileSync(path.join(rpDir, 'f.txt'), 'x');
const rpExpect = fs.realpathSync(path.join(rpDir, 'f.txt'));
fs.realpath(path.join(rpDir, 'f.txt'), ok(record('realpath'), 'realpath', function (r, p) {
    r('realpath ' + (p === rpExpect));
}));
fs.realpath(path.join(rpDir, 'nope'), fail(record('realpath-missing'), 'realpath-missing', function (r, e) {
    r('realpath-missing ' + e.code);
}));

// --- rename ------------------------------------------------------------
const rnDir = path.join(root, 'rn');
fs.mkdirSync(rnDir);
fs.writeFileSync(path.join(rnDir, 'from.txt'), 'x');
fs.rename(path.join(rnDir, 'from.txt'), path.join(rnDir, 'to.txt'), ok(record('rename'), 'rename', function (r) {
    r('rename ' + fs.existsSync(path.join(rnDir, 'to.txt')) + ' ' + !fs.existsSync(path.join(rnDir, 'from.txt')));
}));
fs.rename(path.join(rnDir, 'to.txt'), path.join(rnDir, 'no-dir', 'c.txt'),
    fail(record('rename-missing-dir'), 'rename-missing-dir', function (r, e) {
        r('rename-missing-dir ' + e.code);
    }));

// --- unlink ------------------------------------------------------------
const ulDir = path.join(root, 'ul');
fs.mkdirSync(ulDir);
fs.writeFileSync(path.join(ulDir, 'victim'), 'x');
fs.unlink(path.join(ulDir, 'victim'), ok(record('unlink'), 'unlink', function (r) {
    r('unlink ' + !fs.existsSync(path.join(ulDir, 'victim')));
}));
fs.unlink(path.join(ulDir, 'victim'), fail(record('unlink-missing'), 'unlink-missing', function (r, e) {
    r('unlink-missing ' + e.code);
}));

// --- writeFile worker error arm ----------------------------------------
fs.writeFile(path.join(root, 'no-dir', 'x'), 'data',
    fail(record('write-missing-dir'), 'write-missing-dir', function (r, e) {
        r('write-missing-dir ' + e.code);
    }));

// --- rm ------------------------------------------------------------------
const rmDir = path.join(root, 'rm');
fs.mkdirSync(path.join(rmDir, 'sub'), { recursive: true });
fs.writeFileSync(path.join(rmDir, 'sub', 'inner.txt'), 'x');
const rmRec = record('rm-recursive');
fs.rm(path.join(rmDir, 'sub'), fail(record('rm-dir-nonrecursive'), 'rm-dir-nonrecursive', function (r, e) {
    r('rm-dir-nonrecursive ' + e.code);
    fs.rm(path.join(rmDir, 'sub'), { recursive: true }, ok(rmRec, 'rm-recursive', function (r2) {
        r2('rm-recursive ' + !fs.existsSync(path.join(rmDir, 'sub')));
    }));
}));

// --- promises ride the same natives -------------------------------------
fs.promises.stat(root).then(function (st) {
    record('promise-stat')('promise-stat ' + st.isDirectory());
}).catch(function (e) {
    record('promise-stat')('promise-stat-err ' + e.code);
});

setTimeout(function () {
    for (let i = 0; i < order.length; i++)
        console.log(lines[order[i]]);
    try { fs.rmSync(root, { recursive: true, force: true }); } catch (e) {}
    console.log('steps', done, 'done');
}, 150);
