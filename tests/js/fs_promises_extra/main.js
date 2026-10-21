(async () => {
    const dir = "tests/tmp/promises";
    fs.rmSync(dir, { recursive: true, force: true });
    await fs.promises.mkdir(dir, { recursive: true });
    await fs.promises.writeFile(dir + "/a.txt", "one");
    await fs.promises.copyFile(dir + "/a.txt", dir + "/b.txt");
    await fs.promises.rename(dir + "/b.txt", dir + "/c.txt");
    console.log("chain", await fs.promises.readFile(dir + "/c.txt", "utf8"));
    console.log("real", (await fs.promises.realpath(dir + "/c.txt")).endsWith("c.txt"));
    await fs.promises.rm(dir, { recursive: true });
    console.log("gone", (() => { try { fs.statSync(dir); return false; } catch (e) { return e.code; } })());
})().catch((e) => { console.log("error", e.code || e.message); process.exitCode = 1; });
