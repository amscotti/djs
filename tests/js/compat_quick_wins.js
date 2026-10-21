// Compatibility quick wins (v0.16.2): the small Node surface that popular
// packages probe for at load time. Every line is a deterministic assertion.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const util = require("util");
const events = require("events");
const url = require("url");
const os = require("os");
const zlib = require("zlib");
const http2 = require("http2");

function line(name, value) { console.log(name + ":", value); }

// ---- global alias --------------------------------------------------
line("global", typeof global === "object" && global === globalThis);

// ---- process ------------------------------------------------------
line("versions.node", typeof process.versions.node === "string" && process.versions.node.length > 0);
line("versions.djs", typeof process.versions.djs === "string");
line("versions.node-format", /^\d+\.\d+\.\d+$/.test(process.versions.node));
line("release.name", process.release.name);
line("features.tls", process.features.tls);
let warned = null;
const onWarning = (w) => { warned = w.name + "/" + w.code + "/" + w.message; };
process.on("warning", onWarning);
process.emitWarning("careful", "DeprecationWarning", "DEP0001");
process.removeListener("warning", onWarning);
line("emitWarning", warned);

// ---- util ---------------------------------------------------------
class Custom {
    [util.inspect.custom]() { return "custom!"; }
}
line("inspect.custom", typeof util.inspect.custom);
line("inspect custom output", util.inspect(new Custom()));
line("types.isProxy", util.types.isProxy(new Proxy({}, {})) + "/" + util.types.isProxy({}));
line("isDeepStrictEqual", util.isDeepStrictEqual({ a: [1, { b: 2 }] }, { a: [1, { b: 2 }] }));
line("isDeepStrictEqual diff", util.isDeepStrictEqual({ a: 1 }, { a: 2 }));
line("getSystemErrorName", util.getSystemErrorName(-2) + "/" + util.getSystemErrorName(-13));
line("stripVT", util.stripVTControlCharacters("\u001b[31mred\u001b[39m"));
line("debuglog", typeof util.debuglog("compat-test"));

// ---- events -------------------------------------------------------
const emitter = new events.EventEmitter();
const listener = () => {};
emitter.on("tick", listener);
line("events.on", typeof events.on);
line("getEventListeners", events.getEventListeners(emitter, "tick")[0] === listener);
line("errorMonitor", typeof events.errorMonitor === "symbol");
line("captureRejections", typeof events.captureRejections === "boolean");

// ---- http2 --------------------------------------------------------
line("http2.constants", http2.constants.HTTP2_HEADER_STATUS + " " + http2.constants.HTTP2_HEADER_METHOD +
    " " + http2.constants.HTTP2_ERROR_REFUSED_STREAM);

// ---- os / path / url / zlib ---------------------------------------
line("os.EOL", JSON.stringify(os.EOL));
line("path.win32.join", path.win32.join("C:\\a\\b", "..", "c"));
line("path.win32.basename", path.win32.basename("C:\\a\\b.txt", ".txt"));
line("path.win32.dirname", path.win32.dirname("C:\\a\\b.txt"));
line("path.win32.sep", path.win32.sep);
line("path.toNamespacedPath", path.toNamespacedPath("/tmp/x") === "/tmp/x");
const httpOptions = url.urlToHttpOptions(new URL("https://user:pw@example.test:8443/a?b=1"));
line("url.urlToHttpOptions", [httpOptions.hostname, httpOptions.port, httpOptions.path, httpOptions.auth].join("|"));
line("zlib.crc32", zlib.crc32(Buffer.from("123456789")).toString(16));

// ---- fs dirents ---------------------------------------------------
const dir = path.join(os.tmpdir(), "djs-dirents-" + String(process.pid));
fs.rmSync(dir, { recursive: true, force: true });
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "file.txt"), "x");
fs.mkdirSync(path.join(dir, "subdir"));
const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
line("fs.Dirent", entries[0] instanceof fs.Dirent);
line("dirents", entries.map((e) => e.name + (e.isDirectory() ? "/" : "")).join(","));
line("stat instanceof", fs.statSync(path.join(dir, "file.txt")) instanceof fs.Stats);
fs.rmSync(dir, { recursive: true, force: true });

// ---- http surface -------------------------------------------------
line("http.Agent", typeof http.Agent === "function");
line("http.globalAgent", typeof http.globalAgent.maxSockets === "number");
line("https.globalAgent", https.globalAgent.protocol);
line("STATUS_CODES", http.STATUS_CODES[404] + "/" + http.STATUS_CODES[500]);
line("METHODS", http.METHODS.indexOf("PATCH") >= 0);
line("maxHeaderSize", typeof http.maxHeaderSize === "number");
line("validateHeaderName", (() => {
    http.validateHeaderName("x-ok");
    try { http.validateHeaderName("bad name"); return "no-throw"; }
    catch (e) { return e.code; }
})());

// ---- CLI surface ---------------------------------------------------
line("path.parse", JSON.stringify(path.parse("/a/b.txt")));
line("path.format", path.format({ dir: "/a", base: "b.txt" }));
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "djs-cli-"));
line("fs.mkdtempSync", fs.statSync(tmpDir).isDirectory());
fs.rmSync(tmpDir, { recursive: true, force: true });
line("fs.accessSync missing", (() => {
    try { fs.accessSync(path.join(os.tmpdir(), "djs-definitely-missing")); return "no-throw"; }
    catch (e) { return e.code; }
})());
line("stdout.hasColors force", process.stdout.hasColors(16, { FORCE_COLOR: "1" }));
line("stdout.hasColors off", process.stdout.hasColors(16, { FORCE_COLOR: "0" }));
line("readline.cursorTo", typeof require("readline").cursorTo);
line("process.exitCode", (() => { process.exitCode = 3; const v = process.exitCode; process.exitCode = 0; return v; })());

const server = http.createServer((req, res) => {
    res.appendHeader("Set-Cookie", "a=1");
    res.appendHeader("Set-Cookie", "b=2");
    res.writeHead(200, { "content-type": "text/plain", "x-headers": String(typeof res.getHeaders) });
    res.end("ok");
});
server.listen(0, "127.0.0.1", () => {
    const port = server.address().port;
    const agent = new http.Agent({ keepAlive: true, maxSockets: 2 });
    let usedAgent = false;
    const original = agent.createConnection.bind(agent);
    agent.createConnection = function (options) { usedAgent = true; return original(options); };
    const req = http.request({ port, hostname: "127.0.0.1", path: "/", agent });
    req.setTimeout(5000);
    req.on("response", (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (c) => { body += c; });
        res.on("end", () => {
            line("agent used", usedAgent);
            line("response body", body);
            line("set-cookie array", JSON.stringify(res.headers["set-cookie"]));
            agent.destroy();
            server.close(() => {
                // ---- require identity ------------------------------------
                line("require.main", require.main === module);
                line("require.cache", typeof require.cache === "object" && !!require.cache[__filename]);
                line("module.parent", module.parent);
                line("module.children", Array.isArray(module.children));

                // ---- module resolution (package.json top-level keys only) --
                // A nested "type" must not make an ESM package look like CJS.
                try {
                    require("./fixtures/type-shadow");
                    line("nested type shadow", "loaded");
                } catch (e) {
                    line("nested type shadow", e.code || e.message);
                }
                // A nested "main" must not hijack entry resolution.
                line("nested main shadow", require("./fixtures/main-shadow").entry);
                line("done", "ok");
            });
        });
    });
    req.on("error", (e) => { line("request error", e.message); server.close(); });
    req.end();
});
