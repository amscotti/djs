setImmediate(() => console.log("imm"));
process.nextTick(() => console.log("tick"));
Promise.resolve().then(() => console.log("prom"));
console.log("sync");
