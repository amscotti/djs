try { fs.readFileSync("tests/js/fixtures/hello.txt\u0000x"); }
catch (e) { console.log("fs", e.name); }
try { require("./missing.cjs\u0000x"); }
catch (e) { console.log("require", e.name); }
