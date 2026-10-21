const crypto = require("crypto");
const subtle = crypto.subtle;

(async function () {
    const digest = Buffer.from(await subtle.digest("SHA-256", Buffer.from("abc")));
    console.log("digest", digest.toString("hex").slice(0, 16), digest.length);

    const hmacKey = await subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, true, ["sign", "verify"]);
    const mac = await subtle.sign({ name: "HMAC" }, hmacKey, Buffer.from("data"));
    console.log("hmac", await subtle.verify({ name: "HMAC" }, hmacKey, mac, Buffer.from("data")),
        await subtle.verify({ name: "HMAC" }, hmacKey, mac, Buffer.from("datA")));

    const jwk = await subtle.exportKey("jwk", hmacKey);
    const importedHmac = await subtle.importKey("jwk", jwk, { name: "HMAC", hash: "SHA-256" }, true, ["verify"]);
    console.log("jwk-oct", jwk.kty, await subtle.verify({ name: "HMAC" }, importedHmac, mac, Buffer.from("data")));

    const aesKey = await subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
    const iv = Buffer.alloc(12, 7);
    const ciphertext = await subtle.encrypt({ name: "AES-GCM", iv: iv }, aesKey, Buffer.from("secret"));
    const plaintext = await subtle.decrypt({ name: "AES-GCM", iv: iv }, aesKey, ciphertext);
    console.log("aes", Buffer.from(plaintext).toString(), Buffer.from(ciphertext).length);

    const tampered = Buffer.from(ciphertext);
    tampered[tampered.length - 1] ^= 1;
    let tamper = "accepted";
    try { await subtle.decrypt({ name: "AES-GCM", iv: iv }, aesKey, tampered); }
    catch (e) { tamper = "rejected"; }
    console.log("aes-tamper", tamper);

    const password = await subtle.importKey("raw", Buffer.from("pw"), { name: "PBKDF2" }, false, ["deriveBits"]);
    const derived = Buffer.from(await subtle.deriveBits({ name: "PBKDF2", salt: Buffer.from("salt"), iterations: 10, hash: "SHA-256" }, password, 128));
    console.log("pbkdf2", derived.equals(crypto.pbkdf2Sync(Buffer.from("pw"), Buffer.from("salt"), 10, 16, "sha256")));

    const hkdfKey = await subtle.importKey("raw", Buffer.from("ikm"), { name: "HKDF" }, false, ["deriveBits"]);
    const hkdf = Buffer.from(await subtle.deriveBits({ name: "HKDF", salt: Buffer.from("salt"), info: Buffer.from("info"), hash: "SHA-256" }, hkdfKey, 256));
    console.log("hkdf", hkdf.equals(crypto.hkdfSync("sha256", Buffer.from("ikm"), Buffer.from("salt"), Buffer.from("info"), 32)));

    const rsa = await subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, hash: "SHA-256" }, true, ["sign", "verify"]);
    const rsaSig = await subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, rsa.privateKey, Buffer.from("msg"));
    console.log("rsa", Buffer.from(rsaSig).length, await subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, rsa.publicKey, rsaSig, Buffer.from("msg")));

    const spki = await subtle.exportKey("spki", rsa.publicKey);
    const importedRsa = await subtle.importKey("spki", spki, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["verify"]);
    console.log("spki", await subtle.verify({ name: "RSASSA-PKCS1-v1_5" }, importedRsa, rsaSig, Buffer.from("msg")));

    const ec = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const ecSig = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, ec.privateKey, Buffer.from("msg"));
    console.log("ecdsa", Buffer.from(ecSig).length, await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, ec.publicKey, ecSig, Buffer.from("msg")));
})().catch(function (e) { console.log("ERR", e.name, e.message); process.exitCode = 1; });
