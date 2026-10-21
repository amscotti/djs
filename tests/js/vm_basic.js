const vm = require("vm");

console.log("vm-this", vm.runInThisContext("1 + 2"));
const ctx = { a: 2 };
console.log("vm-new", vm.runInNewContext("a * 5", ctx));
console.log("vm-isolated", vm.runInNewContext("typeof process", ctx));
const s = new vm.Script("({ x: a + 1 })");
console.log("vm-script", JSON.stringify(s.runInNewContext({ a: 4 })));
try {
    vm.runInThisContext("throw new Error('boom')");
} catch (e) {
    console.log("vm-throw", e.code, /boom/.test(e.message));
}
try {
    vm.runInNewContext("return 1", {});
} catch (e) {
    console.log("vm-syntax", e.code);
}
