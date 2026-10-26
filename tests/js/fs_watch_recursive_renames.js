// Recursive watching across a rename-away: the moved directory's watchers
// are dropped (Linux walk) or simply stop (native FSEvents), and the rest of
// the tree keeps reporting.
const fs = require("fs");
const os = require("os");
const path = require("path");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-rn-"));
const outside = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-rn-out-"));
fs.mkdirSync(path.join(root, "a"));
fs.mkdirSync(path.join(root, "b"));
const seen = [];
let done = false;

const watcher = fs.watch(root, { recursive: true }, function (event, filename) {
    if (typeof filename === "string" && filename.indexOf("live.txt") >= 0) seen.push(filename);
    if (seen.length > 0 && !done) finish();
});

function finish() {
    done = true;
    try { watcher.close(); } catch (e) {}
    console.log("rename-away-still-watching", seen.length > 0,
                seen.some(function (f) { return f.indexOf(path.join("b", "live.txt")) >= 0 || f === "live.txt"; }));
    console.log("done");
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
}

setTimeout(function () {
    fs.renameSync(path.join(root, "a"), path.join(outside, "a"));
    setTimeout(function () { fs.writeFileSync(path.join(root, "b", "live.txt"), "x"); }, 300);
}, 300);

setTimeout(function () {
    if (done) return;
    done = true;
    try { watcher.close(); } catch (e) {}
    console.log("rename-away-still-watching", seen.length > 0, false);
    console.log("done");
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
    process.exitCode = 1;
}, 8000);
