const mod = require("./a/mod.cjs");
console.log(mod.load());
setTimeout(() => console.log("deferred", mod.load()), 5);
