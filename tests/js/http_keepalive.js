const http = require("http");
const net = require("net");

function makeParser() {
    const st = { buf: Buffer.alloc(0), res: [] };
    st.feed = function (chunk) {
        st.buf = Buffer.concat([st.buf, chunk]);
        for (;;) {
            const text = st.buf.toString("latin1");
            const idx = text.indexOf("\r\n\r\n");
            if (idx < 0) return;
            const lines = text.slice(0, idx).split("\r\n");
            const status = Number(lines[0].split(" ")[1]);
            const headers = {};
            for (let k = 1; k < lines.length; k++) {
                const c = lines[k].indexOf(":");
                if (c > 0) headers[lines[k].slice(0, c).toLowerCase()] = lines[k].slice(c + 1).trim();
            }
            const cl = Number(headers["content-length"] || 0);
            if (st.buf.length < idx + 4 + cl) return;
            const body = st.buf.slice(idx + 4, idx + 4 + cl).toString();
            st.buf = st.buf.slice(idx + 4 + cl);
            st.res.push({ status: status, headers: headers, body: body });
        }
    };
    return st;
}

function waitFor(p, n) {
    return new Promise(function (resolve, reject) {
        const deadline = Date.now() + 5000;
        (function poll() {
            if (p.res.length >= n) return resolve(p.res[n - 1]);
            if (Date.now() > deadline) return reject(new Error("timeout waiting for response " + n));
            setTimeout(poll, 5);
        })();
    });
}

(async function () {
    const srv = http.createServer(function (req, res) {
        const chunks = [];
        req.on("data", function (c) { chunks.push(c); });
        req.on("end", function () {
            res.end("ok:" + req.method + ":" + req.url + ":" + Buffer.concat(chunks).length);
        });
    });
    await new Promise(function (r) { srv.listen(0, "127.0.0.1", r); });
    const port = srv.address().port;
    const p = makeParser();
    const sock = net.connect(port, "127.0.0.1");
    sock.on("data", function (c) { p.feed(c); });
    await new Promise(function (r) { sock.on("connect", r); });

    sock.write("GET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    const r1 = await waitFor(p, 1);
    console.log("keepalive-1", r1.status, r1.body, r1.headers.connection);
    sock.write("GET /b HTTP/1.1\r\nHost: x\r\n\r\n");
    const r2 = await waitFor(p, 2);
    console.log("keepalive-2", r2.status, r2.body, r2.headers.connection);

    sock.write("GET /p1 HTTP/1.1\r\nHost: x\r\n\r\nGET /p2 HTTP/1.1\r\nHost: x\r\n\r\n");
    await waitFor(p, 4);
    console.log("pipelined", p.res[2].body, p.res[3].body);

    sock.write("POST /chunk HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n");
    sock.write("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    const rc = await waitFor(p, 5);
    console.log("chunked", rc.status, rc.body);

    sock.write("POST /expect HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n");
    const r100 = await waitFor(p, 6);
    console.log("continue", r100.status, r100.body);
    sock.write("abc");
    const rb = await waitFor(p, 7);
    console.log("expect-body", rb.status, rb.body);

    sock.end();

    const hs = net.connect(port, "127.0.0.1");
    let raw = Buffer.alloc(0);
    hs.on("data", function (c) { raw = Buffer.concat([raw, c]); });
    await new Promise(function (r) { hs.on("connect", r); });
    hs.write("HEAD /a HTTP/1.1\r\nHost: x\r\n\r\n");
    await new Promise(function (resolve) {
        const check = function () {
            if (raw.toString("latin1").indexOf("\r\n\r\n") >= 0) return resolve();
            setTimeout(check, 5);
        };
        check();
    });
    const headText = raw.toString("latin1");
    const headEnd = headText.indexOf("\r\n\r\n");
    console.log("head", /^HTTP\/1.1 200/.test(headText), /content-length: \d+/i.test(headText),
        raw.length === headEnd + 4);
    hs.destroy();

    srv.headersTimeout = 300;
    const tsock = net.connect(port, "127.0.0.1");
    await new Promise(function (r) { tsock.on("connect", r); });
    tsock.write("GET / HTTP/1.1\r\nHost: x\r\n");
    const closed = await new Promise(function (resolve) {
        tsock.on("close", function () { resolve(true); });
        setTimeout(function () { resolve(false); }, 1500);
    });
    console.log("header-timeout", closed);

    srv.close();
})().catch(function (e) {
    console.log("ERR", e.message);
    process.exitCode = 1;
});
