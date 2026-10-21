// HTTP keep-alive benchmark: one Node client, one server binary at a time.
// Usage: node bench/http-bench.js <binary> <server.js> <port> [seconds] [concurrency]
const http = require("http");
const { spawn } = require("child_process");
const path = require("path");

const bin = process.argv[2];
const app = process.argv[3];
const port = Number(process.argv[4] || 3456);
const seconds = Number(process.argv[5] || 4);
const concurrency = Number(process.argv[6] || 50);

if (!bin || !app) {
    console.error("usage: node bench/http-bench.js <binary> <server.js> <port> [seconds] [concurrency]");
    process.exit(1);
}

const isDjs = path.basename(bin) === "djs";
const args = isDjs ? ["-A", app] : [app];
const env = Object.assign({}, process.env, { PORT: String(port), NODE_ENV: "production" });
const child = spawn(bin, args, { env: env, stdio: ["ignore", "pipe", "pipe"] });
let serverLog = "";
child.stdout.on("data", function (d) { serverLog += d.toString(); });
child.stderr.on("data", function (d) { serverLog += d.toString(); });
child.on("exit", function (code) {
    if (code !== null && code !== 0 && !stopping) {
        console.error("server exited early", code, serverLog.slice(0, 2000));
        process.exit(1);
    }
});
let stopping = false;

function requestOnce(p) {
    return new Promise(function (resolve) {
        const req = http.get({ host: "127.0.0.1", port: port, path: p, agent: false }, function (res) {
            res.resume();
            res.on("end", resolve);
        });
        req.on("error", resolve);
        req.setTimeout(1000, function () { req.destroy(); resolve(); });
    });
}

async function waitReady() {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
        await requestOnce("/");
        try {
            await new Promise(function (resolve, reject) {
                const req = http.get({ host: "127.0.0.1", port: port, path: "/", agent: false }, function (res) {
                    res.resume();
                    res.on("end", resolve);
                });
                req.on("error", reject);
                req.setTimeout(500, function () { req.destroy(new Error("timeout")); });
            });
            return;
        } catch (e) {
            await new Promise(function (r) { setTimeout(r, 100); });
        }
    }
    throw new Error("server did not become ready: " + serverLog.slice(0, 2000));
}

function load(p, durationMs) {
    return new Promise(function (resolve) {
        const agent = new http.Agent({ keepAlive: true, maxSockets: concurrency });
        const deadline = Date.now() + durationMs;
        const latencies = [];
        let count = 0, errors = 0, active = 0, finished = false;
        function finish() {
            if (finished) return;
            finished = true;
            agent.destroy();
            latencies.sort(function (a, b) { return a - b; });
            const pct = function (q) { return latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * q))] || 0; };
            resolve({
                path: p,
                rps: count / (durationMs / 1000),
                count: count,
                errors: errors,
                p50: pct(0.50),
                p99: pct(0.99)
            });
        }
        function worker() {
            if (finished) return;
            if (Date.now() >= deadline) {
                if (--active === 0) finish();
                return;
            }
            const started = process.hrtime.bigint();
            const req = http.get({ host: "127.0.0.1", port: port, path: p, agent: agent }, function (res) {
                res.resume();
                res.on("end", function () {
                    latencies.push(Number(process.hrtime.bigint() - started) / 1e6);
                    count++;
                    worker();
                });
            });
            req.on("error", function () {
                errors++;
                worker();
            });
        }
        for (let i = 0; i < concurrency; i++) { active++; worker(); }
        setTimeout(finish, durationMs + 2000);
    });
}

(async function () {
    await waitReady();
    await load("/", 1000);
    const results = [];
    for (let round = 0; round < 2; round++) {
        for (const p of ["/", "/json"]) {
            results.push(await load(p, seconds * 1000));
        }
    }
    const merged = {};
    for (const r of results) {
        if (!merged[r.path]) merged[r.path] = [];
        merged[r.path].push(r);
    }
    for (const p of Object.keys(merged)) {
        const rows = merged[p];
        const med = function (k) { const v = rows.map(function (r) { return r[k]; }).sort(function (a, b) { return a - b; }); return v[Math.floor(v.length / 2)]; };
        console.log("RESULT " + path.basename(bin) + " " + p + " rps=" + med("rps").toFixed(1) +
            " p50=" + med("p50").toFixed(2) + " p99=" + med("p99").toFixed(2) +
            " errors=" + rows.reduce(function (a, r) { return a + r.errors; }, 0));
    }
    stopping = true;
    child.kill("SIGTERM");
    setTimeout(function () { child.kill("SIGKILL"); process.exit(0); }, 500);
})().catch(function (e) {
    console.error("BENCH FAIL", e.message);
    stopping = true;
    child.kill("SIGKILL");
    process.exit(1);
});
