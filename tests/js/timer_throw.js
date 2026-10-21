setTimeout(() => { throw new Error("timer boom"); }, 0);
console.log("scheduled");
