const t = setTimeout(() => console.log("bad"), 5);
console.log("bigint", typeof t._id === "bigint");
clearTimeout(t);
setTimeout(() => console.log("timer-ok"), 1);
