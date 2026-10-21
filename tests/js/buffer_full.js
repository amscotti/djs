const assert = require("assert");

const b = Buffer.alloc(24);
assert.strictEqual(b.writeUInt16BE(0x1234, 0), 2);
assert.strictEqual(b.writeInt32LE(-2, 2), 6);
assert.strictEqual(b.writeFloatBE(1.5, 6), 10);
assert.strictEqual(b.writeDoubleLE(2.5, 10), 18);
assert.strictEqual(b.readUInt16BE(0), 0x1234);
assert.strictEqual(b.readInt32LE(2), -2);
assert.strictEqual(b.readFloatBE(6), 1.5);
assert.strictEqual(b.readDoubleLE(10), 2.5);
console.log("numbers", b.subarray(0, 6).toString("hex"));

const big = Buffer.alloc(16);
big.writeBigUInt64BE(12345678901234567890n, 0);
big.writeBigInt64LE(-42n, 8);
console.log("bigint", big.readBigUInt64BE(0).toString(), big.readBigInt64LE(8).toString());

const v = Buffer.alloc(8);
v.writeUIntLE(0x123456, 0, 3);
v.writeIntBE(-1000, 3, 3);
v.writeUIntBE(0xABCDEF, 6, 2);
console.log("variable", v.subarray(0, 8).toString("hex"), v.readUIntLE(0, 3), v.readIntBE(3, 3));

const src = Buffer.from("0123456789");
const dst = Buffer.alloc(5);
console.log("copy", src.copy(dst, 0, 2, 7), dst.toString());
console.log("indexOf", src.indexOf("34"), src.indexOf(Buffer.from("67")), src.indexOf(0x35), src.lastIndexOf("5"));
console.log("includes", src.includes("89"), src.includes("nope"));

const filled = Buffer.alloc(6, "ab");
console.log("fill", filled.toString());
const pat = Buffer.alloc(5).fill("xy");
console.log("fill-pattern", pat.toString());

console.log("json", JSON.stringify(Buffer.from([1, 2, 255])));
console.log("swap16", Buffer.from("01020304", "hex").swap16().toString("hex"));
console.log("swap32", Buffer.from("0102030405060708", "hex").swap32().toString("hex"));
console.log("swap64", Buffer.from("0102030405060708", "hex").swap64().toString("hex"));

const url = Buffer.from("hello?~", "utf8").toString("base64url");
console.log("base64url", url, Buffer.from(url, "base64url").toString());
console.log("isEncoding", Buffer.isEncoding("utf8"), Buffer.isEncoding("base64url"), Buffer.isEncoding("wat"));

const original = Buffer.from("abc");
const copy = Buffer.from(original);
original[0] = 90;
console.log("copy-semantics", copy.toString());

let range = "none";
try { b.readUInt32BE(23); } catch (e) { range = e.name + ":" + e.code; }
console.log("range", range);

const out = { type: "Buffer", data: [104, 105] };
assert.deepStrictEqual(Buffer.from("hi").toJSON(), out);
console.log("toJSON-deep", "ok");
