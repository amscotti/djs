const http = require("http");

const server = http.createServer(function (req, res) {
    let body = [];
    req.on("data", d => body.push(d));
    req.on("end", function () {
        if (req.url === "/hello") {
            res.setHeader("x-test", "yes");
            res.end("world");
        } else if (req.url === "/echo" && req.method === "POST") {
            res.writeHead(201, { "content-type": "text/plain" });
            res.end(Buffer.concat(body));
        } else {
            res.statusCode = 404;
            res.end("missing");
        }
    });
});

function request(port, path, method, payload, next) {
    const req = http.request({ host: "127.0.0.1", port: port, path: path, method: method || "GET" }, function (res) {
        const chunks = [];
        res.on("data", d => chunks.push(d));
        res.on("end", function () { next(res, Buffer.concat(chunks)); });
    });
    req.on("error", e => console.log("error", e.code));
    if (payload) req.write(payload);
    req.end();
}

server.listen(0, "127.0.0.1", function () {
    const port = server.address().port;
    console.log("listen", port > 0);
    request(port, "/hello", "GET", null, function (res, body) {
        console.log("get", res.statusCode, res.headers["x-test"], body.toString());
        request(port, "/echo", "POST", "payload", function (res2, body2) {
            console.log("post", res2.statusCode, res2.headers["content-type"], body2.toString());
            request(port, "/nope", "GET", null, function (res3, body3) {
                console.log("missing", res3.statusCode, body3.toString());
                server.close(function () { console.log("closed"); });
            });
        });
    });
});
