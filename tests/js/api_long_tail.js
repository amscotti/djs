const crypto = require("crypto");
const util = require("util");
const url = require("url");
const fs = require("fs");
const timers = require("timers");

console.log("ppid", typeof process.ppid, process.ppid > 0, typeof timers.setImmediate);
process.title = "djs-test";
console.log("title", process.title);

const bytes = new Uint8Array(4);
crypto.getRandomValues(bytes);
console.log("random", bytes.length, bytes.some(function (b) { return b !== 0; }));

const ac = new AbortController();
const any = AbortSignal.any([new AbortController().signal, ac.signal]);
ac.abort("stop");
console.log("any", any.aborted, any.reason);

const parsed = util.parseArgs({
    args: ["--name", "djs", "-v", "file.js"],
    options: { name: { type: "string" }, verbose: { type: "boolean", short: "v" } },
    allowPositionals: true
});
console.log("parse", parsed.values.name, parsed.values.verbose, parsed.positionals[0]);
console.log("style", JSON.stringify(util.styleText("bold", "x")));

const fileUrl = url.pathToFileURL("tests/js/api_long_tail.js");
console.log("url", fileUrl.protocol, url.fileURLToPath(fileUrl));

console.log("glob", JSON.stringify(fs.globSync("tests/js/fixtures/tls/*.pem")));
fs.glob("tests/js/fixtures/tls/*.key", function (err, matches) {
    console.log("glob-cb", err === null, matches.length);
});
