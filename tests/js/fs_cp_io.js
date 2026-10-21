const fs = require("fs");
const base = "tests/tmp/fs_extra";
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

(async function () {
    try { fs.rmSync(base, { recursive: true, force: true }); } catch (e) {}
    fs.mkdirSync(base + "/src/sub", { recursive: true });
    fs.writeFileSync(base + "/src/a.txt", "a");
    fs.writeFileSync(base + "/src/sub/b.txt", "b");

    const events = [];
    const watcher = fs.watch(base + "/src", { recursive: true }, function (type, name) { events.push(name); });
    await sleep(100);
    fs.writeFileSync(base + "/src/sub/c.txt", "c");
    await sleep(500);
    watcher.close();
    console.log("watch", events.indexOf("sub/c.txt") >= 0);

    fs.cpSync(base + "/src", base + "/dst", { recursive: true });
    console.log("cp", fs.readFileSync(base + "/dst/a.txt", "utf8"), fs.readFileSync(base + "/dst/sub/b.txt", "utf8"));

    const wfd = fs.openSync(base + "/vec.bin", "w+");
    const written = fs.writevSync(wfd, [Buffer.from("ab"), Buffer.from("cd")]);
    fs.closeSync(wfd);
    const rfd = fs.openSync(base + "/vec.bin", "r");
    const parts = [Buffer.alloc(1), Buffer.alloc(3)];
    const read = fs.readvSync(rfd, parts, 0);
    fs.closeSync(rfd);
    console.log("vec", written, read, parts[0].toString(), parts[1].toString());

    const blob = await fs.openAsBlob(base + "/src/a.txt", { type: "text/plain" });
    console.log("blob", blob.size, blob.type);
    await fs.promises.cp(base + "/src", base + "/dst2", { recursive: true });
    console.log("cp-promise", fs.existsSync(base + "/dst2/sub/b.txt"));
})();
