try { fs.readFileSync("tests/js"); } catch (e) { console.log("dir", e.code, e.syscall); }
// /dev/full exists on Linux but not on macOS, so the ENOSPC mapping is only
// observable there.
if (fs.existsSync("/dev/full"))
    try { fs.writeFileSync("/dev/full", "abc"); } catch (e) { console.log("full", e.code, e.syscall); }
else
    console.log("full skip");
