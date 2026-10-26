// Client keep-alive pooling: bounded connections for a concurrent burst,
// reuse for a follow-up request, and no reuse for an explicit
// "Connection: close". Covers the plain, TLS and fetch paths.
const http = require("http");
const https = require("https");
const path = require("path");

function get(mod, options) {
    return new Promise(function (resolve, reject) {
        mod.get(options, function (res) {
            let body = "";
            res.on("data", function (c) { body += c; });
            res.on("end", function () { resolve(body); });
        }).on("error", reject);
    });
}

(async function () {
    let httpConns = 0;
    const httpServer = http.createServer(function (req, res) { res.end("ok"); });
    httpServer.on("connection", function () { httpConns++; });
    await new Promise(function (r) { httpServer.listen(0, "127.0.0.1", r); });
    const httpPort = httpServer.address().port;

    const agent = new http.Agent({ keepAlive: true, maxSockets: 4, keepAliveMsecs: 3000 });
    const burst = await Promise.all(Array.from({ length: 20 }, function () {
        return get(http, { port: httpPort, host: "127.0.0.1", path: "/", agent: agent });
    }));
    console.log("http burst", httpConns, burst.filter(function (b) { return b === "ok"; }).length);

    console.log("http sequential", await get(http, {
        port: httpPort, host: "127.0.0.1", path: "/", agent: agent
    }), httpConns);

    await get(http, {
        port: httpPort, host: "127.0.0.1", path: "/", agent: agent,
        headers: { connection: "close" }
    });
    console.log("http close", httpConns);

    console.log("http after-close", await get(http, {
        port: httpPort, host: "127.0.0.1", path: "/", agent: agent
    }), httpConns);

    // fetch uses the global agent; cap it so the burst must queue.
    http.globalAgent.maxSockets = 4;
    const fetched = await Promise.all(Array.from({ length: 20 }, function () {
        return fetch("http://127.0.0.1:" + httpPort + "/").then(function (r) { return r.text(); });
    }));
    console.log("fetch burst", httpConns, fetched.filter(function (b) { return b === "ok"; }).length);
    console.log("fetch sequential", await (await fetch("http://127.0.0.1:" + httpPort + "/")).text(), httpConns);

    agent.destroy();
    httpServer.close();

    const dir = path.join(__dirname, "..", "fixtures", "tls");
    let tlsConns = 0;
    const httpsServer = https.createServer({
        cert: path.join(dir, "cert.pem"),
        key: path.join(dir, "key.pem")
    }, function (req, res) { res.end("secure"); });
    httpsServer.on("connection", function () { tlsConns++; });
    await new Promise(function (r) { httpsServer.listen(0, "127.0.0.1", r); });
    const httpsPort = httpsServer.address().port;

    const tlsAgent = new https.Agent({ keepAlive: true, maxSockets: 2, keepAliveMsecs: 3000 });
    const tlsBurst = await Promise.all(Array.from({ length: 10 }, function () {
        return get(https, {
            protocol: "https:", port: httpsPort, host: "127.0.0.1", path: "/", agent: tlsAgent,
            rejectUnauthorized: false
        });
    }));
    console.log("https burst", tlsConns, tlsBurst.filter(function (b) { return b === "secure"; }).length);
    console.log("https sequential", await get(https, {
        protocol: "https:", port: httpsPort, host: "127.0.0.1", path: "/", agent: tlsAgent,
        rejectUnauthorized: false
    }), tlsConns);

    tlsAgent.destroy();
    httpsServer.close();
})().catch(function (e) {
    console.log("ERR", e && (e.code || e.message));
    process.exitCode = 1;
});
