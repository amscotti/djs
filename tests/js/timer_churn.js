const before = process.memoryUsage().rss;
for (let i = 0; i < 200000; i++)
    clearTimeout(setTimeout(() => {}, 10000));
const deltaMb = (process.memoryUsage().rss - before) / (1024 * 1024);
console.log(deltaMb < 20 ? "churn-ok" : "churn-fail");
setTimeout(() => console.log("timer-ok"), 1);
