const { parentPort, workerData } = require("worker_threads");
parentPort.postMessage({ value: workerData.n * 7 });
