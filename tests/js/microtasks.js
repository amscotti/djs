Promise.resolve().then(() => {
    console.log("p1");
    return Promise.resolve();
}).then(() => console.log("p2"));
queueMicrotask(() => console.log("m1"));
console.log("sync");
