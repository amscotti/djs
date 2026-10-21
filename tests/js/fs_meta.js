const dir = "tests/tmp/meta";
try { fs.mkdirSync(dir); } catch (e) {}
try { fs.mkdirSync(dir); console.log("mkdir", "unexpected"); }
catch (e) { console.log("mkdir", e.code); }
const p = dir + "/f.txt";
fs.writeFileSync(p, "a");
fs.appendFileSync(p, "b");
console.log("append", fs.readFileSync(p, "utf8"));
const st = fs.statSync(p);
console.log("stat", st.isFile(), st.isDirectory(), st.size);
try { fs.mkdirSync(dir + "/sub"); } catch (e) {}
fs.writeFileSync(dir + "/sub/x", "x");
console.log("readdir", fs.readdirSync(dir).sort().join(","));
fs.unlinkSync(p);
try { fs.statSync(p); } catch (e) { console.log("missing", e.code, e.syscall); }
fs.unlinkSync(dir + "/sub/x");
