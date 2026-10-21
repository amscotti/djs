const assert = require("assert");
const strict = require("assert/strict");
const nodeModule = require("module");

assert.ok(true);
assert.equal(1, "1");
assert.notEqual(1, "2");
assert.strictEqual("a", "a");
assert.notStrictEqual(1, "1");
console.log("basic", "ok");

assert.deepEqual({ a: [1, { b: 2 }] }, { a: [1, { b: 2 }] });
assert.deepStrictEqual(Buffer.from("abc"), Buffer.from("abc"));
assert.deepStrictEqual(new Map([["k", { n: 1 }]]), new Map([["k", { n: 1 }]]));
assert.deepStrictEqual(new Set([1, 2]), new Set([2, 1]));
assert.deepStrictEqual(new Date(5), new Date(5));
assert.deepStrictEqual(/x/g, /x/g);
const cyclicA = { name: "a" }; cyclicA.self = cyclicA;
const cyclicB = { name: "a" }; cyclicB.self = cyclicB;
assert.deepStrictEqual(cyclicA, cyclicB);
console.log("deep", "ok");

let failed = 0;
try { assert.strictEqual(1, "1"); } catch (e) {
    failed++;
    console.log("assertion-error", e.name, e.code, e.operator, e.actual === 1, e.expected === "1");
}
try { assert.deepStrictEqual({ a: 1 }, { a: "1" }); } catch (e) { failed++; console.log("deep-mismatch", e.code); }
try { assert.ok(false, "custom message"); } catch (e) { failed++; console.log("message", e.message); }
console.log("failed", failed);

const thrown = assert.throws(function () { throw new TypeError("bad type"); }, TypeError);
console.log("throws-class", thrown.message);
assert.throws(function () { throw new Error("regex hit"); }, /regex/);
assert.throws(function () { throw new Error("validate me"); }, function (e) { return e.message === "validate me"; });
assert.doesNotThrow(function () { return 1; });
console.log("throws", "ok");

assert.match("hello world", /world/);
assert.doesNotMatch("hello", /bye/);
assert.ifError(null);
console.log("match", "ok");

console.log("strict", strict.equal === assert.strictEqual, assert.strict === strict);

(async function () {
    await assert.rejects(Promise.reject(new Error("nope")), /nope/);
    await assert.rejects(async function () { throw new TypeError("later"); }, TypeError);
    await assert.doesNotReject(Promise.resolve(1));
    console.log("rejects", "ok");

    const localRequire = nodeModule.createRequire(__filename);
    const fixture = localRequire("./fixtures/module_value.js");
    console.log("createRequire", fixture.answer);
    console.log("isBuiltin", nodeModule.isBuiltin("fs"), nodeModule.isBuiltin("node:fs"), nodeModule.isBuiltin("not-a-real-module"));
    console.log("builtinModules", nodeModule.builtinModules.indexOf("stream/promises") !== -1);
})().catch(function (e) { console.log("ASYNC-ERR", e.message); process.exitCode = 1; });
