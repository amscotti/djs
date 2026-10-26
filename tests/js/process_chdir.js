// process.chdir: success, relative fs resolution, error shape and restore.
const fs = require("fs");
const os = require("os");
const path = require("path");

const before = process.cwd();
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "djs-chdir-"));

console.log("chdir-returns", process.chdir(dir) === undefined);
console.log("chdir-cwd", process.cwd() === fs.realpathSync(dir));
fs.writeFileSync("relative.txt", "x");
console.log("chdir-relative", fs.readFileSync("relative.txt", "utf8") === "x");
try {
    process.chdir(path.join(dir, "missing"));
    console.log("chdir-missing none");
} catch (e) {
    console.log("chdir-missing", e.code, e.syscall, e.errno);
}
try {
    process.chdir(42);
    console.log("chdir-type none");
} catch (e) {
    console.log("chdir-type", e.name, e.code);
}
process.chdir(before);
console.log("chdir-restored", process.cwd() === before);
fs.rmSync(dir, { recursive: true, force: true });
