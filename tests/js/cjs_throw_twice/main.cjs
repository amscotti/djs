for (let i = 1; i <= 2; i++) {
    try { require("./bad.cjs"); } catch (e) { console.log(i, e.message); }
}
