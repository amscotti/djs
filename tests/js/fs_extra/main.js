const dir = "tests/tmp/extra";
fs.rmSync(dir, { recursive: true, force: true });
fs.mkdirSync(dir + "/a/b", { recursive: true });
fs.writeFileSync(dir + "/a/one.txt", "one");
console.log("read", fs.readFileSync(dir + "/a/one.txt", "utf8"), fs.readFileSync(dir + "/a/one.txt") instanceof Buffer);

fs.copyFileSync(dir + "/a/one.txt", dir + "/a/two.txt");
console.log("copy", fs.readFileSync(dir + "/a/two.txt", "utf8"));
try { fs.copyFileSync(dir + "/a/one.txt", dir + "/a/two.txt", 1); console.log("excl-missing"); }
catch (e) { console.log("excl", e.code); }

fs.renameSync(dir + "/a/two.txt", dir + "/a/three.txt");
console.log("rename", fs.readFileSync(dir + "/a/three.txt", "utf8"));
console.log("realpath", fs.realpathSync(dir + "/a/../a/three.txt").endsWith("three.txt"));

fs.writeFileSync(dir + "/a/latin.txt", "é", { encoding: "latin1" });
console.log("latin", fs.readFileSync(dir + "/a/latin.txt").length, fs.readFileSync(dir + "/a/latin.txt")[0]);

try { fs.rmSync(dir + "/a", {}); console.log("rm-no-recursive"); }
catch (e) { console.log("rm-nodir", e.code); }
fs.copyFileSync(dir + "/a/three.txt", dir + "/a/three.txt");
console.log("self-copy", fs.readFileSync(dir + "/a/three.txt", "utf8"));
fs.writeFileSync(dir + "/a/mode.txt", "m", { mode: 0o600 });
console.log("write-mode", (fs.statSync(dir + "/a/mode.txt").mode & 0o777).toString(8));
fs.copyFileSync(dir + "/a/mode.txt", dir + "/a/mode2.txt");
console.log("copy-mode", (fs.statSync(dir + "/a/mode2.txt").mode & 0o777).toString(8));
fs.writeFileSync(dir + "/a/enc.txt", "hello");
console.log("hex", fs.readFileSync(dir + "/a/enc.txt", "hex"), fs.readFileSync(dir + "/a/enc.txt", "base64"));
fs.writeFileSync(dir + "/a/enc.bin", "é", "latin1");
console.log("latin", fs.readFileSync(dir + "/a/enc.bin", "latin1").charCodeAt(0));
try { fs.mkdirSync(dir + "/a/one.txt", { recursive: true }); console.log("mkdir-file"); }
catch (e) { console.log("mkdir-file", e.code); }

fs.rmSync(dir, { recursive: true, force: true });
console.log("gone", (() => { try { fs.statSync(dir); return false; } catch (e) { return e.code; } })());
