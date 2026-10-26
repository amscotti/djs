// unref() detaches the watcher from the event loop, like Node. This process
// must exit after the timer even though the watcher was never closed; runtime
// teardown then closes it.
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-unref-"));
const watcher = fs.watch(dir, function () {});
watcher.unref();

setTimeout(function () {
    fs.rmSync(dir, { recursive: true, force: true });
    console.log("unref-exited");
}, 100);
