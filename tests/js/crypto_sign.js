const c = require("crypto");
const path = require("path");
const priv = path.join(__dirname, "..", "fixtures", "keys", "rsa-private.pem");
const pub = path.join(__dirname, "..", "fixtures", "keys", "rsa-public.pem");

const sig = c.sign("RSA-SHA256", Buffer.from("hello"), priv);
console.log("sign", sig.length > 0);
console.log("verify", c.verify("RSA-SHA256", Buffer.from("hello"), pub, sig));
console.log("verify-bad", c.verify("RSA-SHA256", Buffer.from("hell0"), pub, sig));

const key = c.createPrivateKey(priv);
const pubKey = c.createPublicKey(pub);
console.log("keyobject", key.type, pubKey.type);
const sig2 = c.sign("sha256", Buffer.from("again"), key);
console.log("keyobject-verify", c.verify("sha256", Buffer.from("again"), pubKey, sig2));
