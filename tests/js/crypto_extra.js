const c = require("crypto");

const key = Buffer.from("2b7e151628aed2a6abf7158809cf4f3c", "hex");
const iv = Buffer.from("000102030405060708090a0b0c0d0e0f", "hex");
const pt = Buffer.from("6bc1bee22e409f96e93d7e117393172a", "hex");
const enc = c.createCipheriv("aes-128-cbc", key, iv);
const ct = Buffer.concat([enc.update(pt), enc.final()]);
console.log("cbc", ct.toString("hex"));
const dec = c.createDecipheriv("aes-128-cbc", key, iv);
console.log("cbc-back", Buffer.concat([dec.update(ct), dec.final()]).toString("hex"));

const g = c.createCipheriv("aes-128-gcm", Buffer.alloc(16), Buffer.alloc(12));
Buffer.concat([g.update(Buffer.alloc(0)), g.final()]);
console.log("gcm-tag", g.getAuthTag().toString("hex"));

const k2 = Buffer.alloc(32, 7), iv2 = Buffer.alloc(12, 3);
const e2 = c.createCipheriv("aes-256-gcm", k2, iv2);
e2.setAAD(Buffer.from("hdr"));
const ct2 = Buffer.concat([e2.update(Buffer.from("hello")), e2.final()]);
const d2 = c.createDecipheriv("aes-256-gcm", k2, iv2);
d2.setAAD(Buffer.from("hdr"));
d2.setAuthTag(e2.getAuthTag());
console.log("gcm-round", Buffer.concat([d2.update(ct2), d2.final()]).toString());

const bad = c.createDecipheriv("aes-256-gcm", k2, iv2);
bad.setAAD(Buffer.from("hdr"));
bad.setAuthTag(Buffer.alloc(16));
try {
    Buffer.concat([bad.update(ct2), bad.final()]);
    console.log("gcm-tamper missed");
} catch (e) {
    console.log("gcm-tamper", e.code);
}

console.log("pbkdf2", c.pbkdf2Sync("password", "salt", 1, 32, "sha256").toString("hex"));

const ikm = Buffer.alloc(22, 0x0b);
const salt = Buffer.from("000102030405060708090a0b0c", "hex");
const info = Buffer.from("f0f1f2f3f4f5f6f7f8f9", "hex");
console.log("hkdf", Buffer.from(c.hkdfSync("sha256", ikm, salt, info, 42)).toString("hex"));
console.log("scrypt", c.scryptSync("", "", 64, { N: 16, r: 1, p: 1 }).toString("hex"));
