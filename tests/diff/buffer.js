console.log(Buffer.from("hé").length);
console.log(Buffer.from("hi").toString("hex"), Buffer.from("hi").toString("base64"));
console.log(Buffer.from("6869", "hex").toString(), Buffer.from("aGk=", "base64").toString());
console.log(Buffer.from([0xe9]).toString("latin1").charCodeAt(0));
console.log(Buffer.concat([Buffer.from("ab"), Buffer.from("cd")]).toString());
console.log(Buffer.alloc(4, "a").toString(), Buffer.alloc(6, "ab").toString());
console.log(Buffer.byteLength(Buffer.from([255])), Buffer.byteLength(new Uint8Array([255])), Buffer.byteLength(new ArrayBuffer(2)));
console.log(Buffer.from("_-8=", "base64").toString("hex"));
console.log(Buffer.from("\ud800").toString("hex"), Buffer.from("😀").toString("hex"));
