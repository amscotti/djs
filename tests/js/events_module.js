const { EventEmitter, once } = require("events");
const e = new EventEmitter();
let log = "";
e.on("a", v => { log += v; });
e.emit("a", 1);
e.once("b", v => { log += v; });
e.emit("b", 2); e.emit("b", 3);
function h() { log += "x"; }
e.on("c", h); e.off("c", h); e.emit("c");
console.log(log, e.listenerCount("a"), e.eventNames().join(","));
once(e, "done").then(v => console.log("once", v[0]));
e.emit("done", 9);
