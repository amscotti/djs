console.log("start");
setTimeout(() => console.log("t0"), 0);
setTimeout(() => console.log("t1"), 0);
Promise.resolve().then(() => console.log("p"));
queueMicrotask(() => console.log("m"));
console.log("end");
