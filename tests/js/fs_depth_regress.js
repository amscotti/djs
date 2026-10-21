const fs = require("fs");
const { Buffer: B } = require("buffer");
const base = "/tmp/djs-fs-regress";
try { fs.rmSync(base, { recursive: true, force: true }); } catch (e) {}
fs.mkdirSync(base);
const p = base + "/p";
let fd = fs.openSync(p, "w+", "600");
console.log("mode", (fs.fstatSync(fd).mode & 511).toString(8));
console.log("wbuffer", fs.writeSync(fd, B.from("ABCDEFGH"), 2, 3, 0));
console.log("content", fs.readFileSync(p, "utf8"));
fs.closeSync(fd);
console.log("constants", fs.constants.O_RDWR, fs.constants.O_CREAT, fs.constants.O_TRUNC);

fs.open(p, "r+", (err, afd) => {
    fs.write(afd, B.from("XYZ"), 1, 2, 0, (err, n, buf) => {
        console.log("asyncwrite", n, buf.length);
        fs.close(afd, () => {
            fs.promises.open(p, "r+").then(async fh => {
                await fh.write(B.from("QQ"), 1, 1, 5);
                await fh.truncate(6);
                await fh.chmod(384);
                await fh.sync();
                const data = await fh.readFile("utf8");
                console.log("handle", data, (await fh.stat()).size, (await fh.stat()).mode & 511);
                await fh.close();
                await fh.close();
                console.log("doubleclose", fh.fd);
                const enc = new TextEncoder().encode("hi");
                console.log("text", enc.length, new TextDecoder().decode(enc));
                try { fs.closeSync(3); } catch (e) { console.log("closed3", e.code); }
                fs.rmSync(base, { recursive: true, force: true });
            });
        });
    });
});
