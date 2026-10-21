setTimeout(() => { console.log("t1"); throw new Error("first"); }, 0);
setTimeout(() => console.log("t2"), 0);
setTimeout(() => console.log("t3"), 0);
