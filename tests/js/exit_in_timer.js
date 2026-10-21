setTimeout(() => {
    console.log("before");
    process.exit(7);
}, 0);
setTimeout(() => console.log("after"), 20);
