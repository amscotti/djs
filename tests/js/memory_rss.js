// process.memoryUsage().rss must be the *current* resident set size, like
// Node's, not a high-water mark. Compare it with ps for the same process.
const { execFileSync } = require("child_process");
const os = require("os");

const rss = process.memoryUsage().rss;
const psKb = Number(execFileSync("ps", ["-o", "rss=", "-p", String(process.pid)])
    .toString().trim());
const ps = psKb * 1024;
const tolerance = Math.max(8 * 1024 * 1024, ps * 0.25);

console.log("rss-positive", rss > 0);
console.log("rss-close", ps > 0 && Math.abs(rss - ps) <= tolerance);
console.log("rss-under-total", rss > 0 && rss < os.totalmem());

// Distinguish current RSS from a high-water mark where the platform allows
// it: on Linux, freeing a large Buffer unmaps it and RSS drops. macOS (and
// Node itself, even with --expose-gc) retains the pages, so only the sanity
// checks above are meaningful there.
let current = true;
if (process.platform === "linux") {
    let big = Buffer.alloc(64 * 1024 * 1024, 1);
    const high = process.memoryUsage().rss;
    big = null;
    for (let i = 0; i < 300; i++) Buffer.alloc(512 * 1024, 1);
    const after = process.memoryUsage().rss;
    current = high - after > 32 * 1024 * 1024;
}
console.log("rss-current", current);
