// Runtime compatibility shims used by undici and other Node libraries.
const asyncHooks = require("node:async_hooks");
const utilTypes = require("node:util/types");
const { Console } = require("node:console");
const sqlite = require("node:sqlite");
const workerThreads = require("node:worker_threads");

class Resource extends asyncHooks.AsyncResource {
    constructor() { super("DJS_TEST"); }
    invoke(fn) { return this.runInAsyncScope(fn, null, 2, 3); }
}
const resource = new Resource();
console.log("async-resource", resource.invoke(function (a, b) { return a + b; }),
    typeof resource.asyncId(), typeof resource.triggerAsyncId());

const store = new asyncHooks.AsyncLocalStorage();
store.run(42, function () { console.log("async-local", store.getStore()); });
console.log("async-local-out", store.getStore());

console.log("util-types", utilTypes.isArrayBuffer(new ArrayBuffer(1)),
    utilTypes.isUint8Array(new Uint8Array(1)),
    utilTypes.isTypedArray(new Uint8Array(1)),
    utilTypes.isDataView(new DataView(new ArrayBuffer(1))));

let captured = "";
const stream = { write: function (s) { captured += s; } };
const con = new Console({ stdout: stream, stderr: stream });
con.log("hello", 42);
console.log("console", captured.trim());

let hits = 0;
const target = new EventTarget();
target.addEventListener("ping", function (event) { hits += event.type === "ping" ? 1 : 0; }, { once: true });
target.dispatchEvent(new Event("ping"));
target.dispatchEvent(new Event("ping"));
console.log("event-target", hits);

const channel = new MessageChannel();
console.log("message-port", channel.port1 instanceof MessagePort, channel.port2 instanceof MessagePort);

console.log("worker-marks", workerThreads.markAsUncloneable({}) !== undefined,
    workerThreads.markAsUntransferable({}) !== undefined);

try {
    new sqlite.DatabaseSync(":memory:");
    console.log("sqlite none");
} catch (e) {
    console.log("sqlite", e.code);
}
