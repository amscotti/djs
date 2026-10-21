const path = require("path");
console.log("scoped", path.basename(require.resolve("./module_value.js")), require.resolve("fs"));
