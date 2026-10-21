var topLevelLeak = 1;
console.log("global-leak", typeof globalThis.topLevelLeak);
console.log("module", typeof module, typeof require, module.id === ".");
console.log("paths", __filename.charAt(0) === "/", __dirname.charAt(0) === "/");
