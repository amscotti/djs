const bytes = new Uint8Array([255, 254, 0, 65, 128, 66]);
fs.writeFileSync("tests/tmp/bin.dat", bytes);
const back = fs.readFileSync("tests/tmp/bin.dat");
console.log("len", back.length);
console.log("same", Array.from(back).join(","));
fs.writeFileSync("tests/tmp/bin2.dat", back);
console.log("roundtrip", Array.from(fs.readFileSync("tests/tmp/bin2.dat")).join(","));
