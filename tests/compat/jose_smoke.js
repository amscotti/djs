const crypto = require("crypto");
const jose = require("jose");

(async function () {
    const secret = new Uint8Array(Buffer.from("a-shared-secret-that-is-long-enough"));
    const token = await new jose.SignJWT({ sub: "user-1" })
        .setProtectedHeader({ alg: "HS256" })
        .setIssuedAt()
        .setExpirationTime("1h")
        .sign(secret);
    const { payload } = await jose.jwtVerify(token, secret);
    console.log("hs256", payload.sub, token.split(".").length);

    const pair = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const pkcs8 = pair.privateKey.export({ type: "pkcs8", format: "pem" });
    const spki = pair.publicKey.export({ type: "spki", format: "pem" });
    const privateKey = await jose.importPKCS8(pkcs8, "RS256");
    const publicKey = await jose.importSPKI(spki, "RS256");
    const rs = await new jose.SignJWT({ scope: "admin" })
        .setProtectedHeader({ alg: "RS256" })
        .setExpirationTime("1h")
        .sign(privateKey);
    const verified = await jose.jwtVerify(rs, publicKey);
    console.log("rs256", verified.payload.scope, rs.split(".").length);
})().catch(function (e) { console.log("jose-error", e.name, e.message); process.exitCode = 1; });
