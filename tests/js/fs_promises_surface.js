const fs = require("fs");
const fsp = require("fs/promises");
const os = require("os");
const path = require("path");

const dir = path.join(os.tmpdir(), "djs-fsp-" + Date.now());
fs.mkdirSync(dir);
fs.writeFileSync(path.join(dir, "a.txt"), "x");
fs.writeFileSync(path.join(dir, "b.txt"), "y");

(async function () {
    const st = await fsp.statfs(dir);
    console.log("statfs", typeof st.bsize, st.blocks >= 1);

    const dirHandle = await fsp.opendir(dir);
    console.log("opendir", dirHandle.path === dir, typeof dirHandle.close);

    const one = await dirHandle.read();
    console.log("dir-read", typeof one.name, typeof one.isFile);
    await dirHandle.close();

    const iterated = [];
    for await (const entry of await fsp.opendir(dir)) iterated.push(entry.name);
    console.log("dir-iterate", iterated.sort().join(","));

    const matches = await fsp.glob("*.txt", { cwd: dir });
    console.log("glob", matches.join(","));

    const fileHandle = await fsp.open(path.join(dir, "a.txt"));
    const buf = await fileHandle.readFile();
    await fileHandle.close();
    console.log("open", buf.toString());
    fs.rmSync(dir, { recursive: true, force: true });
})();
