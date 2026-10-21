const express = require("express");
const path = require("path");

const app = express();
app.use(express.static(path.join(__dirname, "public")));

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
    const pct = job.pct;
    const polling = job.done ? "" : ' hx-get="/progress" hx-trigger="every 400ms" hx-swap="outerHTML"';
    const lines = job.log.map((m, i) =>
        '<li class="' + (i === job.log.length - 1 && !job.done ? "current" : "") + '">' + m + "</li>"
    ).join("");
    return '<div id="job" class="panel"' + polling + ">" +
        '<div class="row"><strong>' + pct + '%</strong><span>' + job.msg + "</span></div>" +
        '<div class="bar"><div class="fill' + (job.done ? " done" : "") + '" style="width:' + pct + '%"></div></div>' +
        "<ul>" + lines + "</ul>" +
        (job.done ? '<p class="ok">Job complete — ' + job.log.length + " steps.</p>" : "") +
        "</div>";
}

app.post("/start", function (req, res) {
    if (job && !job.done) {
        res.send(render());
        return;
    }
    job = { pct: 0, msg: STEPS[0], log: [STEPS[0]], done: false, step: 0 };
    if (job.timer) clearInterval(job.timer);
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
    res.send(render());
});

app.get("/progress", function (req, res) {
    res.send(render());
});

app.get("/api/status", function (req, res) {
    res.type("application/json").send(JSON.stringify(job ? { pct: job.pct, done: job.done } : { pct: 0, done: true }));
});

const port = Number(process.env.PORT || 3001);
app.listen(port, "127.0.0.1", function () {
    console.log("listening http://127.0.0.1:" + port);
});
