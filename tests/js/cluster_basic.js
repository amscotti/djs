const cluster = require("cluster");
const http = require("http");

if (cluster.isPrimary) {
    const port = 39000 + (process.pid % 1000);
    let ready = 0;
    const workers = [];
    function get() {
        return new Promise(function (resolve, reject) {
            http.get({ host: "127.0.0.1", port: port, path: "/" }, function (res) {
                let body = "";
                res.on("data", function (d) { body += d; });
                res.on("end", function () { resolve(body); });
            }).on("error", reject);
        });
    }
    async function run() {
        for (let i = 0; i < 4; i++) {
            const body = await get();
            console.log("response", /^worker[12]$/.test(body) ? "ok" : "bad");
        }
        console.log("workers", Object.keys(cluster.workers).length);
        workers.forEach(function (w) { w.kill(); });
        setTimeout(function () { process.exit(0); }, 100);
    }
    for (let i = 0; i < 2; i++) {
        const w = cluster.fork({ CLUSTER_PORT: String(port) });
        workers.push(w);
        w.on("message", function (m) {
            if (m && m.ready) {
                ready += 1;
                if (ready === 2) run();
            }
        });
    }
} else {
    http.createServer(function (req, res) { res.end("worker" + cluster.worker.id); })
        .listen(Number(process.env.CLUSTER_PORT), "127.0.0.1", function () {
            process.send({ ready: true, id: cluster.worker.id });
        });
}
