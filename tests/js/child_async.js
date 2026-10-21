const cp = require("child_process");
function run(fn) { return new Promise(function (resolve) { fn(resolve); }); }

(async function () {
    let r = await run(function (done) {
        cp.exec("printf hi", function (e, out) { done({ e: e, out: out }); });
    });
    console.log("exec", r.e === null, JSON.stringify(r.out));

    r = await run(function (done) {
        cp.execFile("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"], function (e, out, err) {
            done({ code: e && e.code, out: out, err: err, signal: e && e.signal });
        });
    });
    console.log("fail", r.code, JSON.stringify(r.out), JSON.stringify(r.err), r.signal);

    r = await run(function (done) {
        cp.exec("printf 0123456789", { maxBuffer: 4 }, function (e) { done(e && e.code); });
    });
    console.log("max", r);

    r = await run(function (done) {
        cp.exec("sleep 1", { timeout: 100 }, function (e) { done({ code: e && e.code, killed: e && e.killed }); });
    });
    console.log("timeout", r.code, r.killed);

    r = await run(function (done) {
        cp.execFile("/bin/sh", ["-c", "printf bytes"], { encoding: "buffer" }, function (e, out) {
            done({ isBuffer: Buffer.isBuffer(out), text: out.toString() });
        });
    });
    console.log("buffer", r.isBuffer, r.text);
})();
