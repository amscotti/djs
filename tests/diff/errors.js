const fs = require("fs");
try { fs.readFileSync("definitely-missing-file.txt"); } catch (e) { console.log(e.code, e.errno < 0); }
try { fs.mkdirSync("tests/tmp", {}); fs.mkdirSync("tests/tmp", {}); } catch (e) { console.log(e.code); }
