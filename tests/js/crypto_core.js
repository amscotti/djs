const crypto = require("crypto");
const fs = require("fs");

const rsa = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const signer = crypto.createSign("sha256");
signer.update("hello ");
signer.update("world");
const signature = signer.sign(rsa.privateKey, "base64");
const verifier = crypto.createVerify("sha256");
verifier.update("hello world");
console.log("rsa", verifier.verify(rsa.publicKey, signature, "base64"), signature.length > 100);

const ec = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
const ecSig = crypto.createSign("sha256").update("payload").sign(ec.privateKey);
console.log("ec", crypto.createVerify("sha256").update("payload").verify(ec.publicKey, ecSig));

console.log("export", rsa.privateKey.export({ type: "pkcs8", format: "pem" }).indexOf("BEGIN PRIVATE KEY") !== -1);
console.log("der", rsa.publicKey.export({ type: "spki", format: "der" }).length > 100);

const symmetric = crypto.createSign("sha256").update("a").update("b").sign(rsa.privateKey);
const joined = crypto.createSign("sha256").update("ab").sign(rsa.privateKey);
console.log("streaming", symmetric.equals(joined), crypto.createVerify("sha256").update("ab").verify(rsa.publicKey, symmetric));

crypto.hkdf("sha256", Buffer.from("ikm"), Buffer.from("salt"), Buffer.from("info"), 32, function (err, key) {
    const sync = crypto.hkdfSync("sha256", Buffer.from("ikm"), Buffer.from("salt"), Buffer.from("info"), 32);
    console.log("hkdf", !err, key.length, key.equals(sync));
});

crypto.generateKeyPair("ec", { namedCurve: "P-384" }, function (err, pair) {
    console.log("async-keypair", !err, typeof pair.privateKey.export({ format: "pem" }));
});

const pem = fs.readFileSync("tests/js/fixtures/cert.pem", "utf8");
const cert = new crypto.X509Certificate(pem);
console.log("x509", cert.subject, cert.issuer === cert.subject);
console.log("x509-fingerprint", cert.fingerprint256.split(":").length === 32);
console.log("x509-host", cert.checkHost("example.test"), cert.checkHost("nope.test"));
console.log("x509-dates", cert.validFromDate instanceof Date, cert.validToDate.getTime() > Date.now());
