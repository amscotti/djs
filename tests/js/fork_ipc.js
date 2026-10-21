const cp = require("child_process");
const child = cp.fork("tests/js/fixtures/fork_child.js");
const seen = [];
child.on("message", function (msg) {
    seen.push(msg.type + (msg.n === undefined ? "" : msg.n));
    if (msg.type === "ready") child.send({ type: "ping", n: 2 });
});
child.on("exit", function (code) {
    console.log("fork", seen.join(","), code, child.connected);
});
