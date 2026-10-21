exports.name = "a";
const b = require("./b.cjs");
exports.fromB = b.name;
exports.bSawA = b.sawA;
console.log("a", exports.fromB, exports.bSawA);
