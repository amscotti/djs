// A directory renamed away and recreated at the same path must rebind the
// recursive walker to the new inode; events from the moved tree must stop.
const fs = require("fs");
const os = require("os");
const path = require("path");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-replace-"));
const outside = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-replace-out-"));
fs.mkdirSync(path.join(root, "a"));
fs.writeFileSync(path.join(root, "a", "old.txt"), "x");
let fresh = false;
let stale = false;

const watcher = fs.watch(root, { recursive: true }, function (event, filename) {
    if (typeof filename === "string") {
        if (filename.indexOf("new.txt") >= 0) fresh = true;
        if (filename.indexOf("stale.txt") >= 0) stale = true;
    }
});

setTimeout(function () {
    fs.renameSync(path.join(root, "a"), path.join(outside, "a"));
    fs.mkdirSync(path.join(root, "a"));
    // The walker rebinds on the rename/create events; give it time before
    // mutating the replacement (inotify cannot replay events from before the
    // watch existed).
    setTimeout(function () {
        fs.writeFileSync(path.join(root, "a", "new.txt"), "x");
    }, 700);
    setTimeout(function () {
        fs.writeFileSync(path.join(outside, "a", "stale.txt"), "x");
    }, 900);
}, 500);

setTimeout(function () {
    try { watcher.close(); } catch (e) {}
    console.log("replace-new", fresh);
    console.log("replace-quiet", !stale);
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
}, 5000);
