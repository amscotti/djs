const a = require("./a.cjs");
exports.name = "b";
exports.sawA = a.name;
console.log("b", exports.sawA);
