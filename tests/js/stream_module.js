const { Readable, Transform, pipeline, Writable } = require("stream");
let out = "";
const r = Readable.from(["a", "b", "c"]);
r.on("data", c => { out += c; });
r.on("end", () => {
    const t = new Transform({ transform(c, enc, cb) { cb(null, c.toUpperCase()); } });
    let upper = "";
    t.on("data", c => { upper += c; });
    t.on("end", () => {
        console.log("readable", out, "transform", upper);
        pipeline(Readable.from(["x", "y"]), new Transform({
            transform(c, enc, cb) { cb(null, c + "!"); }
        }), new Writable({
            write(c, enc, cb) { out += c; cb(); }
        }), err => console.log("pipeline", err ? "err" : out.slice(3)));
    });
    t.write("hi"); t.end();
});
