// Recursive watching across a rename-away: the moved subtree must go quiet
// (Linux prunes its watchers; native FSEvents no longer covers it), while the
// rest of the tree keeps reporting.
const fs = require("fs");
const os = require("os");
const path = require("path");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-rn-"));
const outside = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-rn-out-"));
fs.mkdirSync(path.join(root, "a"));
fs.mkdirSync(path.join(root, "b"));
const seen = [];
let phase = 0;
let done = false;

const watcher = fs.watch(root, { recursive: true }, function (event, filename) {
    if (typeof filename === "string") seen.push([filename, phase]);
    if (phase >= 3 && typeof filename === "string" && filename.indexOf("live.txt") >= 0 && !done) finish();
});

function movedQuiet() {
    return seen.every(function (e) {
        return !(e[1] === 2 && e[0].indexOf("probe") >= 0);
    });
}

function finish() {
    done = true;
    try { watcher.close(); } catch (e) {}
    const watching = seen.some(function (e) {
        return e[1] >= 3 && (e[0] === "b/live.txt" || e[0] === "live.txt");
    });
    console.log("rename-away-still-watching", watching);
    console.log("rename-away-moved-quiet", movedQuiet());
    console.log("done");
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
}

setTimeout(function () {
    phase = 1;
    fs.renameSync(path.join(root, "a"), path.join(outside, "a"));
    setTimeout(function () {
        phase = 2;
        fs.writeFileSync(path.join(outside, "a", "probe.txt"), "x");
        setTimeout(function () {
            phase = 3;
            fs.writeFileSync(path.join(root, "b", "live.txt"), "x");
        }, 700);
    }, 700);
}, 500);

setTimeout(function () {
    if (done) return;
    done = true;
    try { watcher.close(); } catch (e) {}
    console.log("rename-away-still-watching", false);
    console.log("rename-away-moved-quiet", movedQuiet());
    console.log("done");
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
    process.exitCode = 1;
}, 9000);
