const express = require("express");
const app = express();

app.get("/", function (req, res) {
    res.type("text/plain").send("ok");
});

app.get("/json", function (req, res) {
    res.json({ ok: true, n: 1 });
});

const port = Number(process.env.PORT) || 3000;
app.listen(port, "127.0.0.1", function () {
    console.log("ready " + port);
});
