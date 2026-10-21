queueMicrotask(() => { throw new Error("microtask boom"); });
console.log("scheduled");
