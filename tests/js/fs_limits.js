try { fs.readFileSync("/dev/zero"); console.log("zero", "unexpected"); }
catch (e) { console.log("zero", e.code); }
