const crypto = require("crypto");

function bench(name, fn) {
    const started = process.hrtime.bigint();
    fn();
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    console.log(name + " " + ms.toFixed(1));
}

const payload = { a: 1, b: "hello", c: [1, 2, 3], nested: { ok: true } };
bench("json-100k", function () {
    let s = "";
    for (let i = 0; i < 100000; i++) {
        s = JSON.stringify(payload);
        JSON.parse(s);
    }
    if (s.length === 0) throw new Error("unreachable");
});

const block = Buffer.alloc(4096, 7);
bench("sha256-5k", function () {
    for (let i = 0; i < 5000; i++) crypto.createHash("sha256").update(block).digest("hex");
});

const buf = Buffer.alloc(16384);
bench("buffer-500k", function () {
    let sum = 0;
    for (let i = 0; i < 500000; i++) {
        const off = (i * 8) % 16000;
        buf.writeUInt32LE(i >>> 0, off);
        sum += buf.readUInt32LE(off);
    }
    if (sum < 0) throw new Error("unreachable");
});

const text = "alpha,beta,gamma,delta,epsilon,zeta,eta,theta".repeat(400);
bench("string-2k", function () {
    let n = 0;
    for (let i = 0; i < 2000; i++) {
        n += text.split(",").length;
        n += text.replace(/alpha/g, "ALPHA").length;
    }
    if (n === 0) throw new Error("unreachable");
});
