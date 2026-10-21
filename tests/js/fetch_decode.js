const http = require("http");
const zlib = require("zlib");

const text = "decoded payload — with unicode ✓";
const gz = zlib.gzipSync(Buffer.from(text));
const br = zlib.brotliCompressSync(Buffer.from(text), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9 } });
console.log("brotli", zlib.brotliDecompressSync(br).toString() === text);

const server = http.createServer(function (req, res) {
    if (req.url === "/gzip") {
        res.writeHead(200, { "content-encoding": "gzip", "content-type": "text/plain" });
        res.end(gz);
    } else if (req.url === "/br") {
        res.writeHead(200, { "content-encoding": "br", "content-type": "text/plain" });
        res.end(br);
    } else {
        res.end(text);
    }
});

server.listen(0, "127.0.0.1", async function () {
    const base = "http://127.0.0.1:" + server.address().port;
    console.log("gzip", (await (await fetch(base + "/gzip")).text()) === text);
    console.log("br", (await (await fetch(base + "/br")).text()) === text);
    console.log("plain", (await (await fetch(base + "/plain")).text()) === text);
    server.close();
});
