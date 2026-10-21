const fs = require("fs");
const fsp = require("fs/promises");
const processModule = require("process");
console.log(typeof fs.readFile, fs === globalThis.fs, fsp === globalThis.fs.promises);
console.log(typeof processModule.platform, processModule.platform);
