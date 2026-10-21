const path = require("path");
const nodeModule = require("module");

console.log("builtin", require.resolve("fs"), require.resolve("node:fs"));

const js = require.resolve("./fixtures/module_value.js");
console.log("js", path.basename(js), js.charAt(0) === "/");

const json = require.resolve("./fixtures/data.json");
console.log("json", path.basename(json));

require("./fixtures/resolve_check.js");
console.log("entry-module", typeof module, module.id);

let missing = "none";
try { require.resolve("./fixtures/does-not-exist.js"); } catch (e) { missing = e.code; }
console.log("missing", missing);

const localRequire = nodeModule.createRequire(__filename);
console.log("create-path", path.basename(localRequire.resolve("./fixtures/module_value.js")));

const urlRequire = nodeModule.createRequire("file://" + __filename);
console.log("create-url", path.basename(urlRequire.resolve("./fixtures/module_value.js")));

const value = localRequire("./fixtures/module_value.js");
console.log("require", value.answer);
