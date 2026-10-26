// More than the old 32-watcher cap: every directory gets its own watcher.
const fs = require("fs");
const os = require("os");
const path = require("path");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-many-"));
const dirs = [];
const watchers = [];
const seen = new Set();
let done = false;

for (let i = 0; i < 40; i++) {
    const dir = path.join(root, "d" + i);
    fs.mkdirSync(dir);
    dirs.push(dir);
    watchers.push(fs.watch(dir, function (event, filename) {
        if (filename === path.basename(dir)) return; // FSEvents self event
        if (filename === "f.txt") seen.add(i);
        if (seen.size === 40 && !done) finish();
    }));
}

function cleanup() {
    for (const w of watchers) {
        try { w.close(); } catch (e) {}
    }
    fs.rmSync(root, { recursive: true, force: true });
}

function finish() {
    done = true;
    cleanup();
    console.log("many-events", seen.size >= 40, seen.size);
    console.log("done");
}

setTimeout(function () {
    for (let i = 0; i < 40; i++) fs.writeFileSync(path.join(dirs[i], "f.txt"), "x");
}, 700);

setTimeout(function () {
    if (done) return;
    done = true;
    cleanup();
    console.log("many-events", seen.size >= 40, seen.size);
    console.log("done");
    process.exitCode = 1;
}, 8000);
