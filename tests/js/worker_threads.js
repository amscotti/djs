const { Worker, isMainThread } = require("worker_threads");
if (isMainThread) {
    const worker = new Worker("tests/js/fixtures/worker_child.js", { workerData: { n: 3 } });
    worker.on("message", function (m) {
        console.log("worker-message", m.value);
        worker.terminate().then(function () {
            console.log("terminated");
            const evaluated = new Worker("const { parentPort } = require('worker_threads'); parentPort.postMessage({ value: 5 });", { eval: true });
            evaluated.on("message", function (m2) {
                console.log("eval-message", m2.value);
                evaluated.terminate().then(function () { console.log("eval-terminated"); });
            });
        });
    });
    worker.on("error", function (e) { console.log("worker-error", e.message); });
} else {
    console.log("should-not-run-in-main");
}
