const fs = require("fs");
const os = require("os");
const path = require("path");

const file = path.join(os.tmpdir(), "djs-unwatch-" + Date.now() + ".txt");
fs.writeFileSync(file, "0");

const listenerOne = function () {};
const listenerTwo = function () {};
const watcherOne = fs.watchFile(file, { interval: 1000 }, listenerOne);
const watcherTwo = fs.watchFile(file, { interval: 1000 }, listenerTwo);

// An unknown listener must not remove anything (Node keeps the others).
fs.unwatchFile(file, function other() {});
console.log("other-ignored", watcherOne._closed === false, watcherTwo._closed === false);

// A named listener removes only its own poller.
fs.unwatchFile(file, listenerOne);
console.log("listener-removed", watcherOne._closed === true, watcherTwo._closed === false);

// No listener removes every poller for the file.
fs.unwatchFile(file);
console.log("all-removed", watcherTwo._closed === true);

fs.unlinkSync(file);
