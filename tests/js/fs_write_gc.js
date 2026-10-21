const path = "tests/tmp/gc_write.bin";
let buf = new Uint8Array(4 * 1024 * 1024);
buf[0] = 7;
buf[buf.length - 1] = 9;
fs.writeFileSync(path, buf);
buf = null;
const back = fs.readFileSync(path);
console.log("sync", back.length, back[0], back[back.length - 1]);

let asyncBuf = new Uint8Array([1, 2, 3, 4]);
fs.writeFile("tests/tmp/gc_async.bin", asyncBuf, (err) => {
    if (err) { console.log("async-error", err.code); return; }
    const out = fs.readFileSync("tests/tmp/gc_async.bin");
    console.log("async", Array.from(out).join(","));
});
asyncBuf = null;
