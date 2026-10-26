// Node's os.tmpdir() returns an absolute path without a trailing separator;
// macOS sets TMPDIR to a path ending in "/".
const tmp = require("os").tmpdir();
console.log("tmpdir-abs", tmp.startsWith("/"));
console.log("tmpdir-no-trailing", tmp === "/" || !tmp.endsWith("/"));
