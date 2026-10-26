// persistent:false unrefs the watcher, but events must still be delivered
// while another timer keeps the loop alive. The watcher is never closed;
// runtime teardown closes it.
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "djs-watch-persistent-"));
let got = false;
fs.watch(dir, { persistent: false }, function () { got = true; });

setTimeout(function () {
    fs.writeFileSync(path.join(dir, "f.txt"), "x");
}, 200);

setTimeout(function () {
    console.log("persistent-event", got);
    fs.rmSync(dir, { recursive: true, force: true });
}, 1400);
