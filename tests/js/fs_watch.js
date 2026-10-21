const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.tmpdir(), "djs-watch-" + Date.now());
fs.mkdirSync(dir);
console.log("watch-type", typeof fs.watch, typeof fs.FSWatcher);

let seen = false;
const w = fs.watch(dir, function (event, filename) {
    seen = true;
    console.log("watch", event, filename);
    w.close();
    fs.rmSync(dir, { recursive: true, force: true });
});
setTimeout(function () { fs.writeFileSync(path.join(dir, "a.txt"), "x"); }, 60);
setTimeout(function () {
    if (!seen) {
        w.close();
        console.log("watch-timeout");
        process.exitCode = 1;
        fs.rmSync(dir, { recursive: true, force: true });
    }
}, 1500);
