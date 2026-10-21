const c = require("crypto");

console.log("sha256", c.createHash("sha256").update("abc").digest("hex"));
console.log("sha1", c.createHash("sha1").update("abc").digest("hex"));
console.log("md5", c.createHash("md5").update("abc").digest("hex"));
console.log("sha512", c.createHash("sha512").update("abc").digest("hex").length);

// Bytes, not their string coercion: 0x00 and 0xff must survive.
const raw = Buffer.from([0, 255, 1, 128]);
console.log("binary", c.createHash("sha256").update(raw).digest("hex"));

const h = c.createHash("sha256");
h.update("a");
h.update(Buffer.from("bc"));
console.log("chunked", h.digest("base64"));

console.log("hmac", c.createHmac("sha256", "key").update("abc").digest("hex"));
console.log("timing", c.timingSafeEqual("abc", "abc"), c.timingSafeEqual("abc", "abd"));
try { c.timingSafeEqual("a", "bb"); } catch (e) { console.log("timing-len", e.name); }

const r1 = c.randomBytes(16), r2 = c.randomBytes(16);
console.log("random", r1.length, Buffer.isBuffer(r1), r1.toString("hex") !== r2.toString("hex"));

const uuid = c.randomUUID();
console.log("uuid", /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid));

try { c.createHash("nope"); } catch (e) { console.log("bad-alg", e.name); }
try {
    const d = c.createHash("sha256");
    d.digest("hex");
    d.digest("hex");
} catch (e) { console.log("double-digest", e.message); }
