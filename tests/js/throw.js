function inner() { throw new Error("kaboom"); }
function outer() { inner(); }
outer();
