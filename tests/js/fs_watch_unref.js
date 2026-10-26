// unref() detaches the watcher from the event loop, like Node, and events
// must still be delivered while it is unreffed. The process exits after the
// final timer even though the watcher was closed explicitly here.
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-unref-"));
let got = false;
const watcher = fs.watch(dir, function () { got = true; });
watcher.unref();

setTimeout(function () {
    fs.writeFileSync(path.join(dir, "f.txt"), "x");
}, 200);

setTimeout(function () {
    console.log("unref-event", got);
    watcher.close();
    fs.rmSync(dir, { recursive: true, force: true });
    console.log("unref-exited");
}, 1200);
