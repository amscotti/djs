const stream = require("stream");
const events = require("events");
const querystring = require("querystring");
const { StringDecoder } = require("string_decoder");
const fs = require("fs");

// Requiring `stream` must return the callable legacy Stream constructor.
console.log("stream", typeof stream, stream === stream.Stream, typeof stream.Readable);

// Express mixes EventEmitter.prototype into objects without calling the ctor.
const mixed = {};
Object.assign(mixed, events.prototype);
let seen = 0;
mixed.on("ping", v => { seen = v; });
mixed.emit("ping", 7);
console.log("mixin", seen);

// V8-style stack introspection used by depd/debug.
Error.prepareStackTrace = function (err, sites) { return sites; };
function captureHere() {
    const holder = {};
    Error.captureStackTrace(holder, captureHere);
    return holder.stack;
}
const sites = captureHere();
console.log("sites", Array.isArray(sites), sites.length > 0, typeof sites[0].getFileName());
Error.prepareStackTrace = undefined;

console.log("paths", typeof __dirname, __filename.endsWith("node_compat.js"), __dirname.length > 0);
console.log("buffer", Buffer.allocUnsafeSlow(4).length, Buffer.isBuffer(Buffer.from("x")),
    Buffer.compare(Buffer.from("a"), Buffer.from("b")));
console.log("qs", querystring.stringify({ a: 1, b: "x y" }));

const decoder = new StringDecoder("utf8");
const bytes = Buffer.from("é");
console.log("decoder", JSON.stringify(decoder.write(bytes.subarray(0, 1)) +
    decoder.write(bytes.subarray(1)) + decoder.end()));

console.log("fsstream", fs.createReadStream(__filename) instanceof fs.ReadStream,
    fs.createWriteStream("/dev/null") instanceof fs.WriteStream);
