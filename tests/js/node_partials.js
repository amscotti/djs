const os = require("os");
const fs = require("fs");
const dgram = require("dgram");

const h0 = process.hrtime();
const t0 = process.hrtime.bigint();
let acc = 0;
for (let i = 0; i < 100000; i++) acc += i;
const h1 = process.hrtime(h0);
console.log("hrtime", typeof t0 === "bigint", process.hrtime.bigint() >= t0, h1.length === 2);

console.log("uptime", process.uptime() >= 0, os.uptime() > 0);
console.log("loadavg", os.loadavg().length === 3, typeof os.loadavg()[0]);

const ifaces = os.networkInterfaces();
console.log("ifaces", Object.keys(ifaces).length > 0, Array.isArray(ifaces.lo));
console.log("userinfo", typeof os.userInfo().username);

const st = fs.statfsSync(".");
console.log("statfs", st.blocks > 0, st.bsize > 0, st.namemax > 0);
console.log("kill", process.kill(process.pid, 0));
const cu = process.cpuUsage();
console.log("cpuusage", cu.user >= 0, cu.system >= 0);
const oldMask = process.umask();
console.log("umask", typeof oldMask === "number", process.umask(oldMask) === oldMask);

const d = dgram.createSocket("udp4");
d.bind(0, "127.0.0.1", function () {
    d.setBroadcast(true);
    d.setTTL(1);
    d.setMulticastTTL(1);
    d.addMembership("239.1.2.3");
    d.dropMembership("239.1.2.3");
    console.log("dgram-options", true);
const ph = require("perf_hooks");
console.log("perfhooks", typeof ph.performance.now, ph.performance.now() >= 0);
console.log("osconst", os.constants.signals.SIGTERM === 15, os.availableParallelism() > 0);
    d.close();
});
