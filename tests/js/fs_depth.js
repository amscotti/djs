const fs = require("fs");
const base = "/tmp/djs-fs-depth";
try { fs.rmSync(base, { recursive: true, force: true }); } catch (e) {}
fs.mkdirSync(base);
const file = base + "/file.txt";
let fd = fs.openSync(file, "w+", 384);
console.log("write", fs.writeSync(fd, "hello"), fs.writeSync(fd, "XY", 1));
const buf = Buffer.alloc(7);
console.log("read", fs.readSync(fd, buf, 0, 7, 0), buf.toString());
const st = fs.fstatSync(fd);
console.log("fstat", st.size, st.isFile(), st.nlink, st.uid >= 0, st.ino > 0);
fs.closeSync(fd);

const st2 = fs.statSync(file);
console.log("stat", st2.isDirectory(), st2.nlink, st2.atimeMs > 0, st2.ctimeMs > 0, typeof st2.mode);
fs.chmodSync(file, 384);
console.log("chmod", (fs.statSync(file).mode & 511).toString(8));

const hard = base + "/hard.txt";
fs.linkSync(file, hard);
console.log("link", fs.statSync(hard).nlink, fs.readFileSync(hard, "utf8"));

const sym = base + "/sym.txt";
fs.symlinkSync("file.txt", sym);
console.log("symlink", fs.readlinkSync(sym), fs.lstatSync(sym).isSymbolicLink(), fs.statSync(sym).isFile(), fs.readFileSync(sym, "utf8"));
fs.truncateSync(file, 2);
console.log("truncate", fs.readFileSync(file, "utf8"), fs.statSync(file).size);

fs.open(file, "r", (err, rfd) => {
    if (err) throw err;
    const b = Buffer.alloc(2);
    fs.read(rfd, b, 0, 2, 0, (err, n) => {
        console.log("async", n, b.toString());
        fs.close(rfd, () => {
            fs.promises.open(file, "r+").then(async fh => {
                await fh.write("ZZ", 0);
                const b2 = Buffer.alloc(2);
                const r = await fh.read(b2, 0, 2, 0);
                console.log("handle", r.bytesRead, b2.toString(), (await fh.stat()).size);
                await fh.close();
                try { fs.readSync(9999, b2, 0, 1, 0); } catch (e) { console.log("badfd", e.code); }
                try { fs.openSync(file, "q"); } catch (e) { console.log("badflags", e.name); }
                try { fs.truncateSync(file, -1); } catch (e) { console.log("badlen", e.name); }
                fs.rmSync(base, { recursive: true, force: true });
            });
        });
    });
});
