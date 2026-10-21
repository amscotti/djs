const z = require("zlib");

const s = "hello ".repeat(20000);
const g = z.gzipSync(s);
console.log("gzip", g[0].toString(16), g[1].toString(16), g.length < s.length);
console.log("gunzip", z.gunzipSync(g).toString() === s);

const d = z.deflateSync(s);
console.log("deflate", z.inflateSync(d).toString() === s);
const r = z.deflateRawSync(s);
console.log("raw", z.inflateRawSync(r).toString() === s);

console.log("empty", z.gunzipSync(z.gzipSync("")).length);

try { z.gunzipSync(g.subarray(0, 20)); } catch (e) { console.log("truncated", e.code); }

// Every byte value must round-trip; this catches string coercion and truncation.
const all = Buffer.alloc(256);
for (let i = 0; i < 256; i++) all[i] = i;
const packedAll = z.gzipSync(all);
console.log("binary", z.gunzipSync(packedAll).equals(all));

const gz = z.createGzip();
const chunks = [];
gz.on("data", c => chunks.push(c));
gz.on("end", () => {
    const packed = Buffer.concat(chunks);
    console.log("stream-packed", packed.length < s.length);
    const gun = z.createGunzip();
    const out = [];
    gun.on("data", c => out.push(c));
    gun.on("end", () => console.log("stream-roundtrip", Buffer.concat(out).toString() === s));
    gun.end(packed);
});
gz.write(s.slice(0, 100000));
gz.end(s.slice(100000));
