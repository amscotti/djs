const http = require("http");

const blob = new Blob(["ab", Buffer.from("cd")], { type: "Text/Plain" });
console.log("blob", blob.size, blob.type, blob.slice(1, 3).text ? "promise" : "missing");

const file = new File(["xyz"], "a.bin", { type: "application/octet-stream", lastModified: 123 });
console.log("file", file.name, file.size, file.lastModified, file.type);

(async function () {
    console.log("text", await blob.text());
    console.log("arrayBuffer", (await blob.arrayBuffer()).byteLength);
    console.log("slice", await blob.slice(1, 3).text());

    const reader = blob.stream().getReader();
    let streamed = "";
    for (;;) {
        const r = await reader.read();
        if (r.done) break;
        streamed += Buffer.from(r.value).toString();
    }
    console.log("stream", streamed);

    const server = http.createServer(function (req, res) {
        const chunks = [];
        req.on("data", function (c) { chunks.push(c); });
        req.on("end", function () {
            const body = Buffer.concat(chunks).toString("latin1");
            console.log("multipart", req.headers["content-type"].indexOf("multipart/form-data; boundary=") === 0);
            console.log("field", body.indexOf('name="field"') !== -1 && body.indexOf("hello") !== -1);
            console.log("filepart", body.indexOf('filename="a.bin"') !== -1 && body.indexOf("xyz") !== -1);
            res.end("ok:" + body.length);
        });
    });
    server.listen(0, "127.0.0.1", async function () {
        const fd = new FormData();
        fd.append("field", "hello");
        fd.append("upload", new Blob(["xyz"], { type: "application/octet-stream" }), "a.bin");
        const res = await fetch("http://127.0.0.1:" + server.address().port + "/upload", { method: "POST", body: fd });
        console.log("response", await res.text());
        server.close();
    });
})().catch(function (e) { console.log("ERR", e.message); process.exitCode = 1; });
