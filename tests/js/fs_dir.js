const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.tmpdir(), "djs-dir-" + Date.now());
fs.mkdirSync(dir);
fs.writeFileSync(path.join(dir, "a.txt"), "a");
fs.mkdirSync(path.join(dir, "sub"));

const d = fs.opendirSync(dir);
let entry;
const names = [];
while ((entry = d.readSync()) !== null) names.push(entry.name + (entry.isDirectory() ? "/" : ""));
d.closeSync();
console.log("opendir", names.sort().join(","));

fs.opendir(dir, function (err, dd) {
    console.log("opendir-async", err ? err.code : typeof dd.readSync);
    if (dd) dd.closeSync();
});

const file = path.join(dir, "a.txt");
let fired = false;
const w = fs.watchFile(file, { interval: 50 }, function (cur, prev) {
    fired = true;
    console.log("watchfile", cur.size, prev.size);
    w.close();
    fs.rmSync(dir, { recursive: true, force: true });
});
setTimeout(function () { fs.writeFileSync(file, "12345"); }, 120);
setTimeout(function () {
    if (!fired) {
        w.close();
        console.log("watchfile-timeout");
        process.exitCode = 1;
        fs.rmSync(dir, { recursive: true, force: true });
    }
}, 1800);
