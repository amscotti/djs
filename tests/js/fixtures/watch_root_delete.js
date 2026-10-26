const fs = require("fs");
const os = require("os");
const path = require("path");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "djs-rootdel-"));
fs.mkdirSync(path.join(root, "sub"));
fs.writeFileSync(path.join(root, "sub", "x.txt"), "x");
fs.watch(root, { recursive: true }, function () {});
setTimeout(function () {
    fs.rmSync(root, { recursive: true, force: true });
}, 300);
// No close(): a pruned walk has no handles left, so the process exits after
// the timers. A leaked watcher keeps the loop alive and the harness timeout
// catches it.
setTimeout(function () {
    console.log("root-delete-survived");
}, 1500);
