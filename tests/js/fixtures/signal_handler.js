process.on("SIGTERM", function () {
    console.log("got SIGTERM");
    process.exit(0);
});
console.log("ready");
setInterval(function () {}, 1000);
