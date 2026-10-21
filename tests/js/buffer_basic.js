console.log(Buffer.from("héllo").length, Buffer.isBuffer(Buffer.from("x")));
console.log(Buffer.from("hi").toString("hex"), Buffer.from("hi").toString("base64"));
console.log(Buffer.from("6869", "hex").toString(), Buffer.from("aGk=", "base64").toString());
console.log(Buffer.from("é", "latin1")[0], Buffer.from([0xe9]).toString("latin1").charCodeAt(0));
console.log(Buffer.concat([Buffer.from("ab"), Buffer.from("cd")]).toString());
console.log(Buffer.byteLength("hé"), Buffer.alloc(4, 7).join(","));
const b = Buffer.from("abcdef");
b.write ? console.log("write") : console.log("no-write");
console.log(b.slice(1, 3).toString(), b.equals(Buffer.from("abcdef")), b.compare(Buffer.from("abcdeg")));
console.log(Buffer.alloc(4, "a").toString(), Buffer.alloc(6, "ab").toString());
const fb = Buffer.alloc(4); fb.fill("a"); console.log(fb.toString());
const wb = Buffer.alloc(8); console.log(wb.write("abc", 0, "utf8"), wb.toString("utf8", 0, 3));
try { Buffer.alloc(4).write("x", 10); } catch (e) { console.log(e.name); }
console.log(Buffer.byteLength(Buffer.from([255])), Buffer.byteLength(new Uint8Array([255])), Buffer.byteLength(new ArrayBuffer(2)));
console.log(Buffer.from("_-8=", "base64").toString("hex"));
console.log(Buffer.from("\ud800").toString("hex"), Buffer.from("😀").toString("hex"));
