const http = require("http");
const net = require("net");
const port = Number(process.env.DJS_NET_PORT);
if (!port) { console.log("no port"); process.exit(1); }

function done(name, value) { console.log(name, value); }

http.get("http://127.0.0.1:" + port + "/", res => {
    let body = "";
    res.on("data", c => { body += c; });
    res.on("end", () => {
        done("http", res.statusCode + " " + res.headers["x-test"] + " " + body.trim());
        fetch("http://127.0.0.1:" + port + "/json").then(r => r.json()).then(obj => {
            done("fetch", obj.ok + " " + obj.n);
            const req = "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\n";
            const s = net.connect(port, "127.0.0.1", () => {
                s.write(req.slice(0, 20));
                s.write(req.slice(20));
                s.end("abc");
            });
            let chunks = [];
            s.on("data", c => chunks.push(c));
            s.on("end", () => {
                const text = Buffer.concat(chunks).toString("utf8");
                done("writes", text.split("\r\n\r\n")[1]);
                http.get("http://127.0.0.1:" + port + "/trunc", res => {
                    res.on("data", () => {});
                }).on("error", e => done("trunc", e.code));
            });
        });
    });
}).on("error", e => { done("http-error", e.code); process.exit(1); });

try {
    http.get({ hostname: "127.0.0.1", port: port, path: "/", headers: { "x-bad": "a\r\nInjected: 1" } });
    done("header", "no-throw");
} catch (e) { done("header", e.code); }

const refused = net.connect(1, "127.0.0.1");
refused.on("error", e => done("refused", e.code));

setTimeout(() => {
    const t = Date.now();
    require("dns").lookup("no-such-host.invalid", e => done("dns", (e && e.code) + " " + (Date.now() - t < 2000)));
}, 10);
