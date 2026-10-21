const http = require("http");
const fs = require("fs");
const path = require("path");
const { Hono } = require("hono");

const app = new Hono();
const PUB = path.join(__dirname, "public");

const TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8"
};

function asset(name) {
    const file = path.join(PUB, name);
    if (!fs.existsSync(file)) return null;
    return fs.readFileSync(file);
}

const STEPS = [
    "Collecting inputs",
    "Fetching upstream data",
    "Transforming records",
    "Rendering fragments",
    "Finalizing"
];

let job = null;

function render() {
    if (!job) {
        return '<div id="job" class="panel"><p class="muted">No job running. Press Start.</p></div>';
    }
    const polling = job.done ? "" : ' hx-get="/progress" hx-trigger="every 400ms" hx-swap="outerHTML"';
    const lines = job.log.map(function (m, i) {
        const cur = (i === job.log.length - 1 && !job.done) ? "current" : "";
        return '<li class="' + cur + '">' + m + "</li>";
    }).join("");
    return '<div id="job" class="panel"' + polling + ">" +
        '<div class="row"><strong>' + job.pct + '%</strong><span>' + job.msg + "</span></div>" +
        '<div class="bar"><div class="fill' + (job.done ? " done" : "") + '" style="width:' + job.pct + '%"></div></div>' +
        "<ul>" + lines + "</ul>" +
        (job.done ? '<p class="ok">Job complete — ' + job.log.length + " steps.</p>" : "") +
        "</div>";
}

app.get("/", function (c) {
    const body = asset("index.html");
    return c.html(body ? body.toString() : "<h1>missing index</h1>");
});

app.get("/app.css", function (c) {
    const body = asset("app.css");
    c.header("content-type", TYPES[".css"]);
    return c.body(body);
});

app.get("/vendor/:file", function (c) {
    const name = path.basename(c.req.param("file"));
    const body = asset(path.join("vendor", name));
    if (!body) return c.text("not found", 404);
    c.header("content-type", TYPES[".js"]);
    return c.body(body);
});

app.post("/start", function (c) {
    if (!job || job.done) {
        job = { pct: 0, msg: STEPS[0], log: [STEPS[0]], done: false, step: 0, timer: null };
        job.timer = setInterval(function () {
            job.step++;
            if (job.step >= STEPS.length) {
                job.pct = 100;
                job.done = true;
                job.msg = "Complete";
                clearInterval(job.timer);
                return;
            }
            job.pct = Math.round((job.step / STEPS.length) * 100);
            job.msg = STEPS[job.step];
            job.log.push(STEPS[job.step]);
        }, 700);
    }
    return c.html(render());
});

app.get("/progress", function (c) { return c.html(render()); });

app.get("/api/status", function (c) {
    return c.json(job ? { pct: job.pct, done: job.done } : { pct: 0, done: true });
});

const server = http.createServer(function (req, res) {
    const chunks = [];
    req.on("data", function (d) { chunks.push(d); });
    req.on("end", function () {
        const body = req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(chunks);
        const url = "http://" + (req.headers.host || "127.0.0.1") + req.url;
        const request = new Request(url, {
            method: req.method,
            headers: req.headers,
            body: body
        });
        let pending;
        try {
            pending = Promise.resolve(app.fetch(request));
        } catch (e) {
            console.log("SYNC", e.message, e.stack);
            res.statusCode = 500;
            res.end("sync: " + e.message);
            return;
        }
        pending.then(function (response) {
            res.statusCode = response.status;
            response.headers.forEach(function (value, key) {
                try { res.setHeader(key, value); } catch (e) { /* skip invalid */ }
            });
            return response.arrayBuffer();
        }).then(function (buf) {
            res.end(Buffer.from(buf));
        }).catch(function (e) {
            res.statusCode = 500;
            res.end("adapter error: " + e.message);
        });
    });
});

const port = Number(process.env.PORT || 3002);
server.listen(port, "127.0.0.1", function () {
    console.log("listening http://127.0.0.1:" + port);
});
