try { fs.readFileSync("tests/js"); } catch (e) { console.log("dir", e.code, e.syscall); }
try { fs.writeFileSync("/dev/full", "abc"); } catch (e) { console.log("full", e.code, e.syscall); }
