const dir = "tests/tmp/deep";
fs.rmSync(dir, { recursive: true, force: true });
let p = dir;
for (let i = 0; i < 70; i++) p += "/d" + i;
fs.mkdirSync(p, { recursive: true });
console.log("deep-made", fs.statSync(p).isDirectory());
fs.rmSync(dir, { recursive: true });
console.log("deep-gone", (() => { try { fs.statSync(dir); return "still"; } catch (e) { return e.code; } })());
