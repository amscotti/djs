const dc = require("diagnostics_channel");
const trace = require("trace_events");
const perf = require("perf_hooks").performance;

let seen = 0;
dc.subscribe("app.test", function (msg) { seen = msg.n; });
dc.channel("app.test").publish({ n: 7 });
console.log("dc", dc.hasSubscribers("app.test"), seen);
console.log("trace", trace.createTracing({ categories: ["x"] }).enabled);

perf.mark("start");
perf.mark("end");
const measure = perf.measure("span", "start", "end");
console.log("perf", typeof measure.duration, perf.getEntriesByType("mark").length, perf.getEntriesByName("span").length);

const http = require("http");
const server = http.createServer(function (req, res) {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write("data: one\n\n");
    setTimeout(function () { res.write("event: custom\ndata: two\n\n"); }, 50);
});
server.listen(0, "127.0.0.1", function () {
    const es = new EventSource("http://127.0.0.1:" + server.address().port + "/");
    const got = [];
    es.onmessage = function (e) { got.push("m:" + e.data); };
    es.addEventListener("custom", function (e) {
        got.push("c:" + e.data);
        es.close();
        server.close(function () { console.log("sse", got.join(","), es.readyState); });
    });
});
