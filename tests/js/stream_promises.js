const { Readable, Transform, Writable } = require("stream");
const { pipeline, finished } = require("stream/promises");

(async function () {
    let out = "";
    await pipeline(
        Readable.from(["a", "b", "c"]),
        new Transform({ transform: function (chunk, enc, cb) { cb(null, chunk.toUpperCase()); } }),
        new Writable({ write: function (chunk, enc, cb) { out += chunk; cb(); } })
    );
    console.log("pipeline", out);

    const sink = new Writable({ write: function (chunk, enc, cb) { cb(); } });
    const done = finished(sink);
    sink.end();
    await done;
    console.log("finished", "ok");

    try {
        await pipeline(
            Readable.from(["x"]),
            new Transform({ transform: function (chunk, enc, cb) { cb(new Error("boom")); } }),
            new Writable({ write: function (chunk, enc, cb) { cb(); } })
        );
        console.log("reject", "missing");
    } catch (e) {
        console.log("reject", e.message);
    }

    const broken = new Writable({ write: function (chunk, enc, cb) { cb(); } });
    const brokenDone = finished(broken);
    broken.destroy(new Error("sink failed"));
    try {
        await brokenDone;
        console.log("finished-reject", "missing");
    } catch (e) {
        console.log("finished-reject", e.message);
    }
})().catch(function (e) { console.log("ERR", e.message); process.exitCode = 1; });
