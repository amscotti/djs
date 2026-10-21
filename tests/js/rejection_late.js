const p = Promise.reject(new Error("late"));
setTimeout(() => p.catch(() => console.log("handled-late")), 10);
