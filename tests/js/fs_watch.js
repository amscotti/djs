const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.tmpdir(), "djs-watch-" + Date.now());
fs.mkdirSync(dir);
console.log("watch-type", typeof fs.watch, typeof fs.FSWatcher);

function cleanup() {
    fs.rmSync(dir, { recursive: true, force: true });
}

let seen = false;
// FSEvents (macOS) also reports the watched directory itself; ignore that
// event and wait for the file, as inotify on Linux does not send it.
const self = path.basename(dir);
const w = fs.watch(dir, function (event, filename) {
    if (filename === self) return;
    seen = true;
    console.log("watch", event, filename);
    w.close();
    cleanup();
});
setTimeout(function () { fs.writeFileSync(path.join(dir, "a.txt"), "x"); }, 60);
setTimeout(function () {
    if (!seen) {
        w.close();
        console.log("watch-timeout");
        process.exitCode = 1;
        cleanup();
    }
}, 4000);
