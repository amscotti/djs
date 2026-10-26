// Recursive watching over a tree larger than the old watcher cap. macOS uses
// one native FSEvents handle; Linux walks the tree with one watcher per
// directory. Both must report the nested path relative to the root.
const fs = require("fs");
const os = require("os");
const path = require("path");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-rec-"));
for (let i = 0; i < 40; i++) fs.mkdirSync(path.join(root, "d" + i));
const target = path.join(root, "d39", "hit.txt");
const seen = [];
let done = false;

const watcher = fs.watch(root, { recursive: true }, function (event, filename) {
    if (typeof filename === "string" && filename.indexOf("hit.txt") >= 0) seen.push(filename);
    if (seen.length > 0 && !done) finish();
});

function nested() {
    return seen.some(function (f) { return f.indexOf("d39") >= 0; });
}

function cleanup() {
    try { watcher.close(); } catch (e) {}
    fs.rmSync(root, { recursive: true, force: true });
}

function finish() {
    done = true;
    cleanup();
    console.log("recursive-event", seen.length > 0, nested());
    console.log("done");
}

setTimeout(function () { fs.writeFileSync(target, "x"); }, 400);

setTimeout(function () {
    if (done) return;
    done = true;
    cleanup();
    console.log("recursive-event", seen.length > 0, nested());
    console.log("done");
    process.exitCode = 1;
}, 5000);
