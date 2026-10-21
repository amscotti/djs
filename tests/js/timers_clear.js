let n = 0;
const a = setTimeout(() => console.log("bad-timeout"), 0);
clearTimeout(a);
clearTimeout(a);
clearTimeout(undefined);
const i = setInterval(() => {
    n += 1;
    console.log("tick", n);
    if (n === 3) clearInterval(i);
}, 5);
setTimeout(() => console.log("late"), 100);
