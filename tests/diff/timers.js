setTimeout(() => console.log("t"), 1);
Promise.resolve().then(() => console.log("p"));
console.log("s");
