const cp = require("child_process");

const started = Date.now();
const timed = cp.spawnSync("sleep", ["2"], { timeout: 150 });
console.log("timeout", timed.status, timed.signal, timed.error.code, Date.now() - started < 1500);

const capped = cp.spawnSync("head", ["-c", "200000", "/dev/zero"], { maxBuffer: 1000 });
console.log("maxbuffer", capped.status, capped.error.code, capped.stdout.length);

const normal = cp.spawnSync("echo", ["hi"]);
console.log("normal", normal.status, normal.stdout.trim());

try {
    cp.execSync("exec sleep 2", { timeout: 150 });
    console.log("exec-timeout missed");
} catch (e) {
    console.log("exec-timeout", e.code);
}
