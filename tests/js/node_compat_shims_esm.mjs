import { AsyncLocalStorage, AsyncResource } from "node:async_hooks";
import { Console } from "node:console";
import { isArrayBuffer, isUint8Array } from "node:util/types";
import { DatabaseSync } from "node:sqlite";

class R extends AsyncResource {
    constructor() { super("esm"); }
}
const r = new R();
console.log("esm-async", typeof r.runInAsyncScope, typeof AsyncLocalStorage);
console.log("esm-types", isArrayBuffer(new ArrayBuffer(1)), isUint8Array(new Uint8Array(1)));
console.log("esm-console", typeof Console);
console.log("esm-sqlite", typeof DatabaseSync);
