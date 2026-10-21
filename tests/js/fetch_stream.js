const http = require("http");

const server = http.createServer(function (req, res) {
    res.writeHead(200, { "content-type": "text/plain" });
    res.write("one\n");
    setTimeout(function () {
        res.write("two\n");
        res.end();
    }, 120);
});

server.listen(0, "127.0.0.1", async function () {
    const response = await fetch("http://127.0.0.1:" + server.address().port + "/");
    console.log("status", response.status, typeof response.body.getReader);
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let chunks = 0;
    let all = "";
    let first = "";
    for (;;) {
        const r = await reader.read();
        if (r.done) break;
        chunks++;
        all += decoder.decode(r.value);
        if (chunks === 1) first = all;
    }
    console.log("incremental", chunks >= 2, "first", JSON.stringify(first.trim()));
    console.log("all", JSON.stringify(all.trim()), "chunks", chunks);
    server.close();
});
