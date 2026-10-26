// os.cpus() carries libuv's real per-core data on both platforms.
const os = require("os");
const { execFileSync } = require("child_process");
const cpus = os.cpus();
const first = cpus[0] || {};
const times = first.times || {};

console.log("cpus-count", cpus.length > 0);
// Containers can report model "unknown"/speed 0 through libuv just as Node
// does there; the structural checks still catch the old placeholder shape.
console.log("cpus-model", typeof first.model === "string" && first.model.length > 0);
console.log("cpus-speed", typeof first.speed === "number" && first.speed >= 0);
console.log("cpus-times", ["user", "nice", "sys", "idle", "irq"].every(function (k) {
    return typeof times[k] === "number" && times[k] >= 0;
}));
console.log("cpus-idle", typeof times.idle === "number" && times.idle > 0);
// On Darwin, verify against the OS rather than just the shape: the old
// glibc-constant bug reported one CPU, and a placeholder model would pass a
// shape-only check.
let real = true;
if (process.platform === "darwin") {
    const ncpu = Number(execFileSync("sysctl", ["-n", "hw.ncpu"]).toString().trim());
    const model = execFileSync("sysctl", ["-n", "machdep.cpu.brand_string"]).toString().trim();
    real = cpus.length === ncpu && first.model === model;
}
console.log("cpus-real", real);
