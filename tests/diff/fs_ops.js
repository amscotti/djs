const fs = require("fs");
const path = require("path");
const os = require("os");
const dir = path.join(os.tmpdir(), "djsdiff-" + process.pid);
fs.rmSync(dir, { recursive: true, force: true });
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "a.txt"), "hello");
fs.copyFileSync(path.join(dir, "a.txt"), path.join(dir, "b.txt"));
fs.renameSync(path.join(dir, "b.txt"), path.join(dir, "c.txt"));
console.log(fs.readFileSync(path.join(dir, "c.txt"), "utf8"));
fs.mkdirSync(path.join(dir, "n/e/s/t"), { recursive: true });
console.log(fs.readdirSync(dir).sort().join(","));
console.log(fs.statSync("README.md").isFile());

fs.copyFileSync(path.join(dir, "c.txt"), path.join(dir, "c.txt"));
console.log("self", fs.readFileSync(path.join(dir, "c.txt"), "utf8"));
fs.writeFileSync(path.join(dir, "m.txt"), "m", { mode: 0o600 });
fs.copyFileSync(path.join(dir, "m.txt"), path.join(dir, "m2.txt"));
console.log("modes", (fs.statSync(path.join(dir, "m.txt")).mode & 0o777).toString(8),
            (fs.statSync(path.join(dir, "m2.txt")).mode & 0o777).toString(8));
console.log("enc", fs.readFileSync(path.join(dir, "c.txt"), "hex"),
            fs.readFileSync(path.join(dir, "c.txt"), "base64"));
fs.writeFileSync(path.join(dir, "l.txt"), "é", "latin1");
console.log("latin", fs.readFileSync(path.join(dir, "l.txt"), "latin1").charCodeAt(0));
fs.writeFileSync(path.join(dir, "plain"), "x");
try { fs.mkdirSync(path.join(dir, "plain"), { recursive: true }); console.log("mkdir-file ok"); }
catch (e) { console.log("mkdir-file", e.code); }
let deep = path.join(dir, "deep");
for (let i = 0; i < 70; i++) deep = path.join(deep, "d" + i);
fs.mkdirSync(deep, { recursive: true });
fs.rmSync(path.join(dir, "deep"), { recursive: true });
console.log("deep", (() => { try { fs.statSync(path.join(dir, "deep")); return "still"; } catch (e) { return e.code; } })());

fs.rmSync(dir, { recursive: true, force: true });
console.log("clean", (() => { try { fs.statSync(dir); return "still"; } catch (e) { return e.code; } })());
