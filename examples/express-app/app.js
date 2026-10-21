const express = require("express");
const path = require("path");

const app = express();

app.use(express.static(path.join(__dirname, "public")));
app.use(express.json());

app.get("/", function (req, res) {
    res.send("hello from djs");
});

app.get("/api/items", function (req, res) {
    res.json({ items: [1, 2, 3], ok: true });
});

app.post("/api/echo", function (req, res) {
    res.json({ received: req.body });
});

app.get("/api/user/:id", function (req, res) {
    res.json({ id: req.params.id });
});

const port = Number(process.env.PORT || 3100);
app.listen(port, "127.0.0.1", function () {
    console.log("listening " + port);
});
