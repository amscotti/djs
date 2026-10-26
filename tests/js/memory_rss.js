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
