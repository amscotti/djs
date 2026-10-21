process.on("rejectionHandled", function (promise) {
    console.log("rejectionHandled", promise instanceof Promise);
});
process.on("unhandledRejection", function (reason, promise) {
    console.log("unhandledRejection", reason.message, promise instanceof Promise);
});

// Handled in the same turn: neither event fires.
const sameTurn = Promise.reject(new Error("same-turn"));
sameTurn.catch(function () { console.log("caught same-turn"); });

// Handled in a later turn: unhandledRejection now, rejectionHandled when the
// catch attaches.
const late = Promise.reject(new Error("late"));
setTimeout(function () {
    late.catch(function () { console.log("caught late"); });
}, 10);

// Never handled: unhandledRejection only (a listener exists, so no abort).
Promise.reject(new Error("never"));

// A handler attached inside the unhandledRejection listener still produces
// rejectionHandled, as it does in Node.
process.on("unhandledRejection", function (reason, promise) {
    if (reason && reason.message === "in-listener") {
        promise.catch(function () { console.log("caught in listener"); });
    }
});
Promise.reject(new Error("in-listener"));
