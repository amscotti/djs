module djs.runtime;

import core.stdc.errno : errno;
import core.stdc.stdlib : calloc, exit, free, malloc, realloc;
import core.stdc.string : memcpy, strlen;
import core.sys.posix.signal : SIGPIPE, SIG_IGN, signal;
import core.sys.posix.unistd : usleep, write;

import djs.apis.bytes : installBytes;
import djs.apis.console : installConsole;
import djs.apis.fs : fsCloseAll, installFs;
import djs.apis.net : installNet, netCloseAll;
import djs.apis.child : installChild;
import djs.apis.crypto : installCrypto, cryptoCloseAll;
import djs.apis.zlib : installZlib, zlibCloseAll;
import djs.apis.vm : installVm;
import djs.apis.tls : installTls, tlsCloseAll, tlsFree;
import djs.apis.dgram : installDgram, dgramCloseAll;
import djs.apis.os : installOs;
import djs.apis.process : installProcess;
import djs.apis.signals : installSignals, signalsCloseAll;
import djs.apis.stdio : installStdio, stdioCloseAll;
import djs.apis.timers : installTimers, timersCloseAll;
import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.modules.esm : installModules;
import djs.modules.path : realPathAlloc;
import djs.registry;

// The prelude is compiled into the binary. Its public surface is built on the
// narrow __djs primitives installed below.
enum string preludeSource =
    import("prelude/01-core.js") ~
    import("prelude/02-fs.js") ~
    import("prelude/03-streams.js") ~
    import("prelude/04-platform.js") ~
    import("prelude/05-http.js") ~
    import("prelude/06-modules.js") ~
    import("prelude/07-net.js") ~
    import("prelude/08-v8.js");

enum string djsVersion = "v0.16.4";
enum size_t defaultMemoryLimit = 256 * 1024 * 1024;
enum size_t defaultStackSize = 1024 * 1024;
enum int maxJobsPerTurn = 10000;
enum int maxTeardownTurns = 200;
enum int maxPumpTurns = 8;

struct RuntimeOptions
{
    bool consoleEnabled = true;
    bool timersEnabled = true;
    bool fsEnabled = true;
    bool netEnabled = true;
    bool processEnabled = true;
    bool modulesEnabled = true;
    size_t memoryLimit = defaultMemoryLimit;
    size_t stackSize = defaultStackSize;
    long timeoutMs = 0; // 0 = no deadline
    string entryDir;    // project root for module containment; empty = cwd
}

struct RejectionEntry
{
    JSValue promise;
    JSValue reason;
}

struct Runtime
{
    JSRuntime* rt;
    JSContext* ctx;
    uv_loop_t* loop;
    uv_prepare_t* prepare;
    uv_idle_t* idle;

    CallbackRegistry registry;

    // X509_STORE* owned by this runtime (void* keeps tls.d types out of
    // runtime.d). Built once before the loop starts.
    void* tlsCaStore;

    bool prepareStarted;
    bool idleActive;
    bool exitRequested;
    bool failed;
    bool shuttingDown;
    int exitCode;

    char** argv;
    int argc;

    char* rootDir;          // malloc'd canonical project root
    char* entryFile;        // malloc'd canonical entry path, or null
    JSValue requireCache;   // JS object: canonical path -> module object
    JSValue mainModule;     // JS object: the entry module (require.main)
    JSValue requireExtensions; // JS object: shared require.extensions table

    bool timedOut;
    ulong deadlineNs; // 0 = none
    void* deadlineHandle;
    size_t memoryLimit;

    // Intrusive lists owned by apis.timers.
    void* timerHead;
    void* timerFree;
    size_t timerFreeCount; // bounded: excess handles are closed, not pooled

    RejectionEntry* rejections;
    size_t rejectionCount;
    size_t rejectionCapacity;

    // Rejections whose 'unhandledRejection' was already emitted and that are
    // kept alive in case a handler arrives later ('rejectionHandled').
    RejectionEntry* reportedRejections;
    size_t reportedRejectionCount;
    size_t reportedRejectionCapacity;

    // Set while 'unhandledRejection' is being emitted for one promise: a
    // handler attached inside that listener must still produce
    // 'rejectionHandled', as it does in Node.
    bool reportingActive;
    bool reportingHandled;
    JSValue reportingPromise;

    // Promises whose rejection became handled after it was reported. The
    // engine callback must not call into JS, so they are drained from the job
    // loop, where 'rejectionHandled' is emitted.
    JSValue* handledPromises;
    size_t handledCount;
    size_t handledCapacity;

    // 'beforeExit' is emitted once, at the first point where the loop has no
    // work left to do; 'exit' once, when teardown begins.
    bool beforeExitEmitted;
    bool exitEmitted;
}

// QuickJS is patched (scripts/patches) to account live ArrayBuffer bytes;
// JS_GetArrayBufferBytes() is the exact figure Node reports as arrayBuffers.
JSValue newTrackedArrayBuffer(JSContext* ctx, Runtime*, const(ubyte)* data,
                              size_t len) @nogc nothrow
{
    return JS_NewArrayBufferCopy(ctx, data, len);
}

Runtime* runtimeOf(JSContext* ctx) @nogc nothrow
{
    if (ctx is null)
        return null;
    return cast(Runtime*) JS_GetContextOpaque(ctx);
}

// Every extern(C) entry point runs its body through this guard. A D Error
// (assert, bounds, null) must never unwind through QuickJS or libuv, so the
// only recovery is to report and leave the process.
JSValue guarded(alias impl)(JSContext* ctx, JSValueConst thisVal, int argc,
                            JSValueConst* argv) @nogc nothrow
{
    try
        return impl(ctx, thisVal, argc, argv);
    catch (Throwable)
    {
        writeFd(2, "djs: internal error\n", 20);
        exit(70);
    }
}

void writeFd(int fd, const(char)* data, size_t len) @nogc nothrow
{
    if (data is null || len == 0)
        return;
    size_t off = 0;
    while (off < len)
    {
        ptrdiff_t n = write(fd, data + off, len - off);
        // EPIPE means the reader closed; the write is ignored (SIGPIPE is
        // ignored at startup, so this returns EPIPE instead of killing us).
        if (n <= 0)
            return;
        off += cast(size_t) n;
    }
}

void writeLiteral(int fd, const(char)* s) @nogc nothrow
{
    writeFd(fd, s, strlen(s));
}

private char* dupSlice(const(char)[] s) @nogc nothrow
{
    char* p = cast(char*) malloc(s.length + 1);
    if (p is null)
        return null;
    if (s.length > 0)
        memcpy(p, s.ptr, s.length);
    p[s.length] = 0;
    return p;
}

private bool installPrimitives(Runtime* self, const(RuntimeOptions)* opts) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    if (jsIsException(global))
        return false;

    JSValue djs = JS_NewObject(ctx);
    if (jsIsException(djs))
    {
        JS_FreeValue(ctx, global);
        return false;
    }

    bool ok = true;
    if (opts.consoleEnabled)
        ok = ok && installConsole(self, djs);
    if (ok && opts.timersEnabled)
        ok = ok && installTimers(self, djs);
    if (ok && opts.fsEnabled)
        ok = ok && installFs(self, djs);
    if (ok && opts.netEnabled)
        ok = ok && installNet(self, djs);
    if (ok)
        ok = ok && installChild(self, djs);
    if (ok)
        ok = ok && installBytes(self, djs);
    if (ok)
        ok = ok && installOs(self, djs);
    if (ok && opts.processEnabled)
        ok = ok && installProcess(self, djs);
    if (ok)
        ok = ok && installCrypto(self, djs);
    if (ok)
        ok = ok && installZlib(self, djs);
        ok = ok && installVm(self, djs);
    if (ok)
        ok = ok && installTls(self, djs);
    if (ok)
        ok = ok && installDgram(self, djs);
    if (ok)
        ok = ok && installSignals(self, djs);
    if (ok)
        ok = ok && installStdio(self, djs);
    if (ok && opts.modulesEnabled)
        ok = ok && installModules(self, djs);
    if (ok)
        ok = addNativeFunction(ctx, djs, "queueMicrotask", &jsQueueMicrotask, 1);

    if (!ok)
    {
        JS_FreeValue(ctx, djs);
        JS_FreeValue(ctx, global);
        return false;
    }
    // Consumes djs.
    if (JS_SetPropertyStr(ctx, global, "__djs", djs) <= 0)
    {
        JS_FreeValue(ctx, global);
        return false;
    }
    JS_FreeValue(ctx, global);
    return true;
}

private extern(C) JSValue microtaskJob(JSContext* ctx, int argc,
                                       JSValueConst* argv) nothrow @nogc
{
    if (argc < 1)
        return jsUndefined();
    return JS_Call(ctx, argv[0], jsUndefined(), 0, null);
}

private extern(C) JSValue jsQueueMicrotaskImpl(JSContext* ctx, JSValueConst, int argc,
                                               JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (argc < 1 || !JS_IsFunction(ctx, argv[0]))
        return throwTypeError(ctx, "queueMicrotask requires a function");
    JSValueConst jobArg = argv[0];
    if (JS_EnqueueJob(ctx, &microtaskJob, 1, &jobArg) < 0)
        return jsException();
    if (self !is null && !self.shuttingDown && !self.failed && !self.exitRequested)
    {
        // A queued job does not ref libuv; nudge the keep-alive handle so the
        // loop cannot exit with microtasks queued.
        if (!self.idleActive && self.idle !is null)
        {
            if (uv_idle_start(self.idle, &onIdle) == 0)
                self.idleActive = true;
        }
    }
    return jsUndefined();
}

extern(C) JSValue jsQueueMicrotask(JSContext* ctx, JSValueConst thisVal, int argc,
                                   JSValueConst* argv) nothrow @nogc
{
    return guarded!jsQueueMicrotaskImpl(ctx, thisVal, argc, argv);
}

private extern(C) int onInterrupt(JSRuntime*, void* opaque) nothrow @nogc
{
    Runtime* self = cast(Runtime*) opaque;
    if (self is null || self.deadlineNs == 0)
        return 0;
    if (uv_hrtime() < self.deadlineNs)
        return 0;
    self.timedOut = true;
    return 1;
}

private void fireTimeout(Runtime* self) @nogc nothrow
{
    if (self is null || self.timedOut || self.exitRequested)
        return;
    self.timedOut = true;
    self.failed = true;
    self.exitCode = 1;
    writeLiteral(2, "djs: timed out\n");
    if (self.loop !is null)
        uv_stop(self.loop);
}

// A ref'd timer would keep a finished script alive; an unref'd one still fires
// while the loop is running for other reasons, which is exactly what a deadline
// needs. It wakes the loop out of poll() so a long timer cannot overrun it.
private extern(C) void onDeadline(uv_timer_t* h) nothrow @nogc
{
    Runtime* self = cast(Runtime*) uv_handle_get_data(cast(uv_handle_t*) h);
    fireTimeout(self);
}

private extern(C) void onPrepare(uv_prepare_t* h) nothrow @nogc
{
    Runtime* self = cast(Runtime*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (self is null || self.shuttingDown || self.failed || self.exitRequested)
        return;
    if (self.deadlineNs != 0 && uv_hrtime() >= self.deadlineNs)
    {
        fireTimeout(self);
        return;
    }
    int r = runtimeDrainJobs(self);
    if (r < 0)
        return;
    if (JS_IsJobPending(self.rt))
    {
        if (!self.idleActive && self.idle !is null)
        {
            if (uv_idle_start(self.idle, &onIdle) == 0)
                self.idleActive = true;
        }
    }
    else if (self.idleActive && self.idle !is null)
    {
        uv_idle_stop(self.idle);
        self.idleActive = false;
    }
}

private extern(C) void onIdle(uv_idle_t* h) nothrow @nogc
{
    Runtime* self = cast(Runtime*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (self is null || self.shuttingDown || self.failed || self.exitRequested)
    {
        uv_idle_stop(h);
        if (self !is null)
            self.idleActive = false;
        return;
    }
    int r = runtimeDrainJobs(self);
    if (r < 0 || !JS_IsJobPending(self.rt))
    {
        uv_idle_stop(h);
        self.idleActive = false;
    }
}

private extern(C) void onControlClosed(uv_handle_t* h) nothrow @nogc
{
    free(h);
}

// Reported rejections are only worth retaining while something listens for
// 'rejectionHandled'; the cap keeps a listener that never runs from holding an
// unbounded number of promise graphs alive.
private enum size_t maxReportedRejections = 1024;

private void freeEntry(JSContext* ctx, ref RejectionEntry e) @nogc nothrow
{
    JS_FreeValue(ctx, e.promise);
    JS_FreeValue(ctx, e.reason);
}

// Removal is a swap with the last entry; callers that iterate must account for
// the element moving under them.
private void removeEntry(RejectionEntry* arr, size_t* count, size_t i) @nogc nothrow
{
    *count -= 1;
    if (i != *count)
        arr[i] = arr[*count];
}

private void freeRejections(Runtime* self) @nogc nothrow
{
    if (self.rejections !is null)
    {
        for (size_t i = 0; i < self.rejectionCount; ++i)
            freeEntry(self.ctx, self.rejections[i]);
        free(self.rejections);
        self.rejections = null;
        self.rejectionCount = 0;
        self.rejectionCapacity = 0;
    }
    if (self.reportedRejections !is null)
    {
        for (size_t i = 0; i < self.reportedRejectionCount; ++i)
            freeEntry(self.ctx, self.reportedRejections[i]);
        free(self.reportedRejections);
        self.reportedRejections = null;
        self.reportedRejectionCount = 0;
        self.reportedRejectionCapacity = 0;
    }
    if (self.handledPromises !is null)
    {
        for (size_t i = 0; i < self.handledCount; ++i)
            JS_FreeValue(self.ctx, self.handledPromises[i]);
        free(self.handledPromises);
        self.handledPromises = null;
        self.handledCount = 0;
        self.handledCapacity = 0;
    }
}

// Takes ownership of `promise` (no dup).
private void addReported(Runtime* self, JSValue promise, JSValue reason) @nogc nothrow
{
    if (self.reportedRejectionCount == self.reportedRejectionCapacity)
    {
        size_t newCap = self.reportedRejectionCapacity == 0 ? 8
                                                           : self.reportedRejectionCapacity * 2;
        RejectionEntry* p = cast(RejectionEntry*) realloc(self.reportedRejections,
                                                          newCap * RejectionEntry.sizeof);
        if (p is null)
        {
            JS_FreeValue(self.ctx, promise);
            JS_FreeValue(self.ctx, reason);
            return;
        }
        self.reportedRejections = p;
        self.reportedRejectionCapacity = newCap;
    }
    self.reportedRejections[self.reportedRejectionCount].promise = promise;
    self.reportedRejections[self.reportedRejectionCount].reason = reason;
    self.reportedRejectionCount += 1;
}

private void queueHandledPromise(Runtime* self, JSValueConst promise) @nogc nothrow
{
    if (self.handledCount == self.handledCapacity)
    {
        size_t newCap = self.handledCapacity == 0 ? 8 : self.handledCapacity * 2;
        JSValue* p = cast(JSValue*) realloc(self.handledPromises,
                                            newCap * JSValue.sizeof);
        if (p is null)
            return;
        self.handledPromises = p;
        self.handledCapacity = newCap;
    }
    self.handledPromises[self.handledCount] = JS_DupValue(self.ctx, promise);
    self.handledCount += 1;
}

// Called from the job loop: safe to call into JS here.
private void emitHandledRejections(Runtime* self) @nogc nothrow
{
    if (self.handledCount == 0)
        return;
    for (size_t i = 0; i < self.handledCount; ++i)
    {
        runtimeEmitProcessEvent(self, "rejectionHandled", self.handledPromises[i],
                                jsUndefined(), null);
        JS_FreeValue(self.ctx, self.handledPromises[i]);
    }
    self.handledCount = 0;
}

private extern(C) void onPromiseRejection(JSContext* ctx, JSValueConst promise,
                                          JSValueConst reason, bool isHandled,
                                          void* opaque) nothrow @nogc
{
    Runtime* self = cast(Runtime*) opaque;
    if (self is null || self.shuttingDown)
        return;
    if (isHandled)
    {
        // A handler arrived. If the rejection was not reported yet, the engine
        // must never see it as unhandled: drop it silently, as Node does when
        // the handler is attached in the same turn.
        for (size_t i = 0; i < self.rejectionCount; ++i)
        {
            if (!jsSamePointer(self.rejections[i].promise, promise))
                continue;
            freeEntry(ctx, self.rejections[i]);
            removeEntry(self.rejections, &self.rejectionCount, i);
            return;
        }
        // The handler arrived while its 'unhandledRejection' listener was
        // running: the entry is detached from both lists, so match it here and
        // let reportUnhandledRejections queue the follow-up event.
        if (self.reportingActive && jsSamePointer(self.reportingPromise, promise))
        {
            self.reportingHandled = true;
            return;
        }
        // It was reported: queue 'rejectionHandled'. Emitting JS from here is
        // unsafe (the engine is inside promise resolution), so the job loop
        // drains the queue.
        for (size_t i = 0; i < self.reportedRejectionCount; ++i)
        {
            if (!jsSamePointer(self.reportedRejections[i].promise, promise))
                continue;
            queueHandledPromise(self, promise);
            freeEntry(ctx, self.reportedRejections[i]);
            removeEntry(self.reportedRejections, &self.reportedRejectionCount, i);
            return;
        }
        return;
    }
    // Already recorded by an earlier callback for the same promise.
    for (size_t i = 0; i < self.rejectionCount; ++i)
        if (jsSamePointer(self.rejections[i].promise, promise))
            return;
    if (self.rejectionCount == self.rejectionCapacity)
    {
        size_t newCap = self.rejectionCapacity == 0 ? 8 : self.rejectionCapacity * 2;
        RejectionEntry* p = cast(RejectionEntry*) realloc(self.rejections,
                                                          newCap * RejectionEntry.sizeof);
        if (p is null)
            return;
        self.rejections = p;
        self.rejectionCapacity = newCap;
    }
    self.rejections[self.rejectionCount].promise = JS_DupValue(ctx, promise);
    self.rejections[self.rejectionCount].reason = JS_DupValue(ctx, reason);
    self.rejectionCount += 1;
}

private bool oomLikely(Runtime* self) @nogc nothrow
{
    if (self is null || self.memoryLimit == 0)
        return false;
    JSMemoryUsage mu = void;
    JS_ComputeMemoryUsage(self.rt, &mu);
    return mu.malloc_size >= cast(long) (self.memoryLimit - self.memoryLimit / 10);
}

// Format an exception to stderr. The message comes from String(value); the
// stack, when present, is printed as its own block. A throwing getter must not
// replace the original exception.
private void printExceptionValue(JSContext* ctx, JSValueConst exc,
                                 const(char)* prefix) @nogc nothrow
{
    writeLiteral(2, prefix);
    size_t len = 0;
    const(char)* text = null;
    if (jsIsSymbol(exc))
    {
        // String(Symbol) throws; print the description instead.
        JSValue desc = JS_GetPropertyStr(ctx, exc, "description");
        if (!jsIsException(desc) && !jsIsUndefined(desc))
        {
            size_t dlen = 0;
            const(char)* d = JS_ToCStringLen2(ctx, &dlen, desc, false);
            writeLiteral(2, "Symbol(");
            if (d !is null)
            {
                writeFd(2, d, dlen);
                JS_FreeCString(ctx, d);
            }
            writeLiteral(2, ")");
        }
        else
        {
            writeLiteral(2, "Symbol()");
        }
        if (!jsIsException(desc))
            JS_FreeValue(ctx, desc);
        else if (JS_HasException(ctx))
        {
            JSValue extra = JS_GetException(ctx);
            JS_FreeValue(ctx, extra);
        }
    }
    else
    {
        if (jsIsNull(exc) && runtimeOf(ctx) !is null && oomLikely(runtimeOf(ctx)))
        {
            writeLiteral(2, "InternalError: out of memory");
        }
        else
        {
            text = JS_ToCStringLen2(ctx, &len, exc, false);
            if (text !is null)
            {
                writeFd(2, text, len);
                JS_FreeCString(ctx, text);
            }
            else
            {
                writeLiteral(2, "<exception>");
                if (JS_HasException(ctx))
                {
                    JSValue extra = JS_GetException(ctx);
                    JS_FreeValue(ctx, extra);
                }
            }
        }
    }
    writeLiteral(2, "\n");

    JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
    if (jsIsException(stack))
    {
        if (JS_HasException(ctx))
        {
            JSValue extra = JS_GetException(ctx);
            JS_FreeValue(ctx, extra);
        }
        return;
    }
    if (!jsIsUndefined(stack) && !jsIsNull(stack))
    {
        size_t slen = 0;
        const(char)* s = JS_ToCStringLen2(ctx, &slen, stack, false);
        if (s !is null)
        {
            if (slen > 0)
            {
                writeFd(2, s, slen);
                if (s[slen - 1] != '\n')
                    writeLiteral(2, "\n");
            }
            JS_FreeCString(ctx, s);
        }
        else if (JS_HasException(ctx))
        {
            JSValue extra = JS_GetException(ctx);
            JS_FreeValue(ctx, extra);
        }
    }
    JS_FreeValue(ctx, stack);
}

void runtimePrintException(Runtime* self, JSContext* ctx) @nogc nothrow
{
    JSValue exc = JS_GetException(ctx);
    printExceptionValue(ctx, exc, "Uncaught ");
    JS_FreeValue(ctx, exc);
}

void runtimeReportUncaught(Runtime* self, JSContext* ctx) @nogc nothrow
{
    if (self.shuttingDown)
        return;
    runtimePrintException(self, ctx);
    self.failed = true;
    // An explicit process.exit(code) is a contract; a later failure in the
    // same turn must not downgrade it to 1.
    if (!self.exitRequested)
        self.exitCode = 1;
    if (self.loop !is null)
        uv_stop(self.loop);
}

// Calls the prelude's process-event hook (__djsEmitProcessEvent). The hook
// runs the listeners and returns true when an unhandled rejection was claimed
// by a listener, which is how Node decides not to abort.
private bool runtimeEmitProcessEvent(Runtime* self, const(char)* name, JSValue a, JSValue b,
                                     bool* result) @nogc nothrow
{
    if (self is null || self.ctx is null || self.shuttingDown)
        return false;
    JSContext* ctx = self.ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    if (jsIsException(global))
        return false;
    JSValue fn = JS_GetPropertyStr(ctx, global, "__djsEmitProcessEvent");
    JS_FreeValue(ctx, global);
    bool ok = false;
    if (JS_IsFunction(ctx, fn))
    {
        JSValue[3] argv = [JS_NewStringLen(ctx, name, strlen(name)),
                           JS_DupValue(ctx, a),
                           JS_DupValue(ctx, b)];
        JSValue r = JS_Call(ctx, fn, jsUndefined(), 3, argv.ptr);
        foreach (v; argv)
            JS_FreeValue(ctx, v);
        if (jsIsException(r))
        {
            JS_FreeValue(ctx, r);
            runtimeReportUncaught(self, ctx);
        }
        else
        {
            if (result !is null)
            {
                int truth = JS_ToBool(ctx, r);
                *result = truth == 1;
            }
            JS_FreeValue(ctx, r);
            ok = true;
        }
    }
    JS_FreeValue(ctx, fn);
    return ok;
}

// True when the prelude's process object has at least one listener for the
// named event. Used to avoid retaining promises nobody can observe.
private bool runtimeHasProcessListener(Runtime* self, const(char)* name) @nogc nothrow
{
    if (self is null || self.ctx is null || self.shuttingDown)
        return false;
    JSContext* ctx = self.ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    if (jsIsException(global))
        return false;
    JSValue fn = JS_GetPropertyStr(ctx, global, "__djsHasProcessListeners");
    JS_FreeValue(ctx, global);
    bool found = false;
    if (JS_IsFunction(ctx, fn))
    {
        JSValue arg = JS_NewStringLen(ctx, name, strlen(name));
        JSValue r = JS_Call(ctx, fn, jsUndefined(), 1, &arg);
        if (!jsIsException(r))
            found = JS_ToBool(ctx, r) == 1;
        JS_FreeValue(ctx, r);
        JS_FreeValue(ctx, arg);
    }
    JS_FreeValue(ctx, fn);
    return found;
}

private void reportUnhandledRejections(Runtime* self) @nogc nothrow
{
    if (self.rejectionCount == 0)
        return;
    if (self.exitRequested || self.failed)
    {
        freeRejections(self);
        return;
    }
    // A promise is only worth retaining when a listener could observe the later
    // 'rejectionHandled'.
    bool trackHandled = runtimeHasProcessListener(self, "rejectionHandled");
    // Detach the pending list: emitting 'unhandledRejection' runs JS, and the
    // engine may call the rejection tracker from inside that call (a GC can
    // release promises). Mutating the array under the loop would skip entries.
    RejectionEntry* pending = self.rejections;
    size_t pendingCount = self.rejectionCount;
    self.rejections = null;
    self.rejectionCount = 0;
    self.rejectionCapacity = 0;
    bool fatal = false;
    for (size_t i = 0; i < pendingCount; ++i)
    {
        bool handled = false;
        self.reportingActive = true;
        self.reportingHandled = false;
        self.reportingPromise = pending[i].promise;
        runtimeEmitProcessEvent(self, "unhandledRejection", pending[i].reason,
                                pending[i].promise, &handled);
        self.reportingActive = false;
        if (!handled)
        {
            printExceptionValue(self.ctx, pending[i].reason, "Uncaught (in promise) ");
            fatal = true;
            freeEntry(self.ctx, pending[i]);
            continue;
        }
        if (!trackHandled || self.reportedRejectionCount >= maxReportedRejections)
        {
            // Nobody can observe a later handler: release the entry now.
            freeEntry(self.ctx, pending[i]);
            continue;
        }
        // Keep the promise, drop the reason: 'rejectionHandled' passes only the
        // promise. Ownership of the promise reference moves to the reported
        // list, so the entry is not freed here.
        JS_FreeValue(self.ctx, pending[i].reason);
        bool handledDuringReport = self.reportingHandled;
        if (handledDuringReport)
            queueHandledPromise(self, pending[i].promise);
        addReported(self, pending[i].promise, jsUndefined());
    }
    free(pending);
    if (fatal)
    {
        freeRejections(self);
        self.failed = true;
        self.exitCode = 1;
        if (self.loop !is null)
            uv_stop(self.loop);
    }
}

// Returns 1 when the queue was drained, 0 when the per-turn budget was hit
// (jobs remain), and -1 when a job threw and the exception has been reported.
int runtimeDrainJobs(Runtime* self) @nogc nothrow
{
    if (self.exitRequested || self.failed)
        return 1;
    int executed = 0;
    for (;;)
    {
        JSContext* jctx = null;
        int r = JS_ExecutePendingJob(self.rt, &jctx);
        if (r < 0)
        {
            // The exception lives in the context returned by the engine; it
            // may differ from the context that started the turn.
            runtimeReportUncaught(self, jctx is null ? self.ctx : jctx);
            return -1;
        }
        if (r == 0)
        {
            // 'rejectionHandled' first: it describes a promise from an earlier
            // turn, while the unhandled set is about this one.
            emitHandledRejections(self);
            reportUnhandledRejections(self);
            return 1;
        }
        executed += 1;
        if (executed >= maxJobsPerTurn)
            return 0;
    }
}

void runtimeRunLoop(Runtime* self) @nogc nothrow
{
    while (!self.exitRequested && !self.failed)
    {
        if (runtimeDrainJobs(self) < 0)
            break;
        if (!uv_loop_alive(self.loop) && !JS_IsJobPending(self.rt))
        {
            // Node emits 'beforeExit' when there is no work left; a listener
            // that schedules more work keeps the process alive.
            if (!self.beforeExitEmitted)
            {
                self.beforeExitEmitted = true;
                runtimeEmitProcessEvent(self, "beforeExit", jsInt(self.exitCode),
                                        jsUndefined(), null);
                if (runtimeDrainJobs(self) < 0)
                    break;
                if (uv_loop_alive(self.loop) || JS_IsJobPending(self.rt))
                    continue;
            }
            break;
        }
        if (JS_IsJobPending(self.rt) && !self.idleActive && self.idle !is null)
        {
            if (uv_idle_start(self.idle, &onIdle) == 0)
                self.idleActive = true;
        }
        uv_run(self.loop, UV_RUN_ONCE);
    }
}

// Bounded loop advancement for the REPL: run ready timers and microtasks
// without blocking on future events.
void runtimePump(Runtime* self) @nogc nothrow
{
    for (int i = 0; i < maxPumpTurns; ++i)
    {
        if (runtimeDrainJobs(self) < 0)
            return;
        uv_run(self.loop, UV_RUN_NOWAIT);
        if (!JS_IsJobPending(self.rt) && i > 0)
            return;
    }
}

enum EvalResult
{
    ok,
    exception,
}

EvalResult runtimeEvalEx(Runtime* self, const(char)* src, size_t len,
                         const(char)* filename, int flags, JSValue* result) @nogc nothrow
{
    // JS_Eval takes an explicit length, but a NUL terminator keeps the buffer
    // usable by the parser's lookahead and by diagnostics.
    char* buf = cast(char*) malloc(len + 1);
    if (buf is null)
    {
        throwInternalError(self.ctx, "out of memory");
        *result = jsException();
        return EvalResult.exception;
    }
    if (len > 0)
        memcpy(buf, src, len);
    buf[len] = 0;
    JSValue v = JS_Eval(self.ctx, buf, len, filename, flags);
    free(buf);
    if (jsIsException(v))
    {
        *result = v;
        return EvalResult.exception;
    }
    if (JS_HasException(self.ctx))
    {
        // Defensive: the engine reported a pending exception without returning
        // JS_EXCEPTION. Leave it pending for the reporter.
        JS_FreeValue(self.ctx, v);
        *result = jsException();
        return EvalResult.exception;
    }
    *result = v;
    return EvalResult.ok;
}

EvalResult runtimeEval(Runtime* self, const(char)* src, size_t len,
                       const(char)* filename, JSValue* result) @nogc nothrow
{
    return runtimeEvalEx(self, src, len, filename, JS_EVAL_TYPE_GLOBAL, result);
}

bool runtimeRunScriptFlags(Runtime* self, const(char)* src, size_t len,
                           const(char)* filename, int flags) @nogc nothrow
{
    JSValue result = jsUndefined();
    EvalResult er = runtimeEvalEx(self, src, len, filename, flags, &result);
    if (er == EvalResult.exception)
    {
        runtimePrintException(self, self.ctx);
        self.failed = true;
        self.exitCode = 1;
        return false;
    }
    JS_FreeValue(self.ctx, result);
    if (runtimeDrainJobs(self) < 0)
        return false;
    runtimeRunLoop(self);
    return !self.failed;
}

bool runtimeRunScript(Runtime* self, const(char)* src, size_t len,
                      const(char)* filename) @nogc nothrow
{
    return runtimeRunScriptFlags(self, src, len, filename, JS_EVAL_TYPE_GLOBAL);
}

bool runtimeInstallPrelude(Runtime* self) @nogc nothrow
{
    JSValue result = jsUndefined();
    EvalResult er = runtimeEval(self, preludeSource.ptr, preludeSource.length,
                                "<prelude>", &result);
    if (er == EvalResult.exception)
    {
        runtimePrintException(self, self.ctx);
        self.failed = true;
        self.exitCode = 1;
        return false;
    }
    JS_FreeValue(self.ctx, result);
    return true;
}

void runtimeRequestExit(Runtime* self, int code) @nogc nothrow
{
    self.exitRequested = true;
    self.exitCode = code;
    if (self.loop !is null)
        uv_stop(self.loop);
}

private char* currentDirAlloc() @nogc nothrow
{
    import core.sys.posix.unistd : getcwd;
    char[4096] buf = void;
    if (getcwd(buf.ptr, buf.length) is null)
        return null;
    return dupSlice(buf[0 .. strlen(buf.ptr)]);
}

Runtime* runtimeCreate(string[] args, RuntimeOptions opts) @nogc nothrow
{
    int loopRc = 0;
    bool loopInited = false, prepInited = false, idleInited = false;
    size_t stackSize = 0;

    // A closed stdout must not kill the runtime; writes then fail with EPIPE.
    signal(SIGPIPE, SIG_IGN);

    Runtime* self = cast(Runtime*) calloc(1, Runtime.sizeof);
    if (self is null)
        return null;
    *self = Runtime.init;
    self.exitCode = 0;
    self.requireCache = jsUndefined();
    self.mainModule = jsUndefined();
    self.requireExtensions = jsUndefined();

    self.argc = cast(int) args.length;
    self.argv = cast(char**) calloc(args.length + 1, char*.sizeof);
    if (self.argv is null)
        goto fail;
    foreach (i, arg; args)
    {
        self.argv[i] = dupSlice(arg);
        if (self.argv[i] is null)
            goto fail;
    }

    self.rootDir = opts.entryDir.length > 0 ? dupSlice(opts.entryDir) : currentDirAlloc();
    if (self.rootDir is null)
        goto fail;
    {
        // Containment compares canonical paths, so the root must be canonical.
        char* canon = realPathAlloc(self.rootDir);
        if (canon !is null)
        {
            free(self.rootDir);
            self.rootDir = canon;
        }
    }

    self.loop = cast(uv_loop_t*) malloc(uv_loop_size());
    if (self.loop is null)
        goto fail;
    loopRc = uv_loop_init(self.loop);
    if (loopRc != 0)
    {
        writeLiteral(2, "djs: init: uv_loop_init: ");
        writeLiteral(2, uv_strerror(loopRc));
        writeLiteral(2, "\n");
        goto fail;
    }
    loopInited = true;

    if (!registryInit(&self.registry, 64))
        goto fail;

    self.rt = JS_NewRuntime();
    if (self.rt is null)
        goto fail;
    JS_SetMemoryLimit(self.rt, opts.memoryLimit);
    self.memoryLimit = opts.memoryLimit;
    // The engine's guard must stay below the real thread stack: asking for a
    // limit at or above it turns runaway recursion into SIGSEGV, not RangeError.
    enum size_t maxJsStack = 4 * 1024 * 1024;
    stackSize = opts.stackSize > maxJsStack ? maxJsStack : opts.stackSize;
    JS_SetMaxStackSize(self.rt, stackSize);
    JS_SetCanBlock(self.rt, false);
    JS_SetHostPromiseRejectionTracker(self.rt, &onPromiseRejection, self);
    if (opts.timeoutMs > 0)
    {
        self.deadlineNs = uv_hrtime() + cast(ulong) opts.timeoutMs * 1_000_000;
        JS_SetInterruptHandler(self.rt, &onInterrupt, self);
    }

    self.ctx = JS_NewContext(self.rt);
    if (self.ctx is null)
        goto fail;
    JS_SetContextOpaque(self.ctx, self);
    self.requireCache = JS_NewObject(self.ctx);

    self.prepare = cast(uv_prepare_t*) malloc(uv_handle_size(UV_PREPARE));
    self.idle = cast(uv_idle_t*) malloc(uv_handle_size(UV_IDLE));
    if (self.prepare is null || self.idle is null)
        goto fail;
    if (uv_prepare_init(self.loop, self.prepare) != 0)
        goto fail;
    prepInited = true;
    if (uv_idle_init(self.loop, self.idle) != 0)
        goto fail;
    idleInited = true;
    uv_handle_set_data(cast(uv_handle_t*) self.prepare, self);
    uv_handle_set_data(cast(uv_handle_t*) self.idle, self);
    if (uv_prepare_start(self.prepare, &onPrepare) != 0)
        goto fail;
    self.prepareStarted = true;
    // The prepare handle drains jobs but must not keep the process alive.
    uv_unref(cast(uv_handle_t*) self.prepare);

    if (opts.timeoutMs > 0)
    {
        uv_timer_t* deadline = cast(uv_timer_t*) malloc(uv_handle_size(UV_TIMER));
        if (deadline is null)
            goto fail;
        if (uv_timer_init(self.loop, deadline) != 0)
        {
            free(deadline);
            goto fail;
        }
        self.deadlineHandle = deadline;
        uv_handle_set_data(cast(uv_handle_t*) deadline, self);
        if (uv_timer_start(deadline, &onDeadline, cast(ulong) opts.timeoutMs, 0) != 0)
            goto fail;
        // Unref'd: it fires while the loop is busy, but never keeps a finished
        // script alive until the deadline.
        uv_unref(cast(uv_handle_t*) deadline);
    }

    if (!installPrimitives(self, &opts))
        goto fail;

    return self;

fail:
    writeLiteral(2, "djs: failed to initialize runtime\n");
    if (self.prepare !is null && prepInited &&
        uv_is_closing(cast(uv_handle_t*) self.prepare) == 0)
        uv_close(cast(uv_handle_t*) self.prepare, &onControlClosed);
    else if (self.prepare !is null && !prepInited)
        free(self.prepare);
    if (self.idle !is null && idleInited &&
        uv_is_closing(cast(uv_handle_t*) self.idle) == 0)
        uv_close(cast(uv_handle_t*) self.idle, &onControlClosed);
    else if (self.idle !is null && !idleInited)
        free(self.idle);
    if (self.deadlineHandle !is null &&
        uv_is_closing(cast(uv_handle_t*) self.deadlineHandle) == 0)
        uv_close(cast(uv_handle_t*) self.deadlineHandle, &onControlClosed);
    if (self.loop !is null)
    {
        // Close callbacks free the handle memory; then close the loop.
        for (int i = 0; i < 4; ++i)
            uv_run(self.loop, UV_RUN_NOWAIT);
        uv_loop_close(self.loop);
        free(self.loop);
    }
    if (self.ctx !is null)
        JS_FreeContext(self.ctx);
    if (self.rt !is null)
        JS_FreeRuntime(self.rt);
    tlsFree(self);
    registryDestroy(&self.registry);
    if (self.argv !is null)
    {
        for (int i = 0; i < self.argc; ++i)
            free(self.argv[i]);
        free(self.argv);
    }
    if (self.rootDir !is null)
        free(self.rootDir);
    free(self);
    return null;
}

int runtimeTeardown(Runtime* self) @nogc nothrow
{
    if (self is null)
        return 70;
    // Every exit path (eval, script, module, uncaught error) funnels through
    // teardown, which is where Node's 'exit' listeners belong: the loop is
    // done, timers are still open, and the exit code is final.
    if (!self.exitEmitted)
    {
        self.exitEmitted = true;
        runtimeEmitProcessEvent(self, "exit", jsInt(self.exitCode), jsUndefined(), null);
    }
    self.shuttingDown = true;

    if (self.ctx !is null)
    {
        timersCloseAll(self);
        fsCloseAll(self);
        netCloseAll(self);
        signalsCloseAll(self);
        stdioCloseAll(self);
        cryptoCloseAll(self);
        zlibCloseAll(self);
        tlsCloseAll(self);
        dgramCloseAll(self);
    }

    if (self.prepare !is null && uv_is_closing(cast(uv_handle_t*) self.prepare) == 0)
        uv_close(cast(uv_handle_t*) self.prepare, &onControlClosed);
    if (self.idle !is null && uv_is_closing(cast(uv_handle_t*) self.idle) == 0)
        uv_close(cast(uv_handle_t*) self.idle, &onControlClosed);
    if (self.deadlineHandle !is null &&
        uv_is_closing(cast(uv_handle_t*) self.deadlineHandle) == 0)
        uv_close(cast(uv_handle_t*) self.deadlineHandle, &onControlClosed);

    bool loopStuck = false;
    if (self.loop !is null)
    {
        // Bounded, non-blocking drain. The first turn clears uv_stop's flag,
        // the following turns run close callbacks and finish requests that are
        // already done. A blocking fs request can never finish here, so the
        // budget is what keeps exit() from hanging. An explicit exit is about
        // to _exit anyway, so it gets a short budget rather than 200 ms.
        int turns = (self.exitRequested || self.failed) ? 20 : maxTeardownTurns;
        for (int i = 0; i < turns; ++i)
        {
            if (uv_loop_alive(self.loop) == 0)
                break;
            uv_run(self.loop, UV_RUN_NOWAIT);
            if (uv_loop_alive(self.loop) != 0)
                usleep(1000);
        }
        loopStuck = uv_loop_alive(self.loop) != 0;
    }

    // The loop drain above released every SSL_CTX that shared the CA store.
    // If it got stuck, a worker may still be in a handshake, so leave the
    // store allocated and let the OS reclaim it at exit.
    if (!loopStuck)
        tlsFree(self);

    int code = self.exitCode;
    if (loopStuck && !self.exitRequested && !self.failed)
        code = 70;

    if (self.ctx !is null)
    {
        freeRejections(self);
        registryFreeAll(self.ctx, &self.registry);
        registryDestroy(&self.registry);
        if (!jsIsUndefined(self.requireCache))
            JS_FreeValue(self.ctx, self.requireCache);
        if (!jsIsUndefined(self.mainModule))
            JS_FreeValue(self.ctx, self.mainModule);
        if (!jsIsUndefined(self.requireExtensions))
            JS_FreeValue(self.ctx, self.requireExtensions);
    }

    if (self.ctx !is null)
        JS_FreeContext(self.ctx);
    if (self.rt !is null)
        JS_FreeRuntime(self.rt);

    if (self.loop !is null)
    {
        if (loopStuck)
        {
            // Never free a loop that still owns handles/requests; the process
            // is leaving and the OS reclaims it. A requested exit is normal,
            // so stay quiet about the leftovers it deliberately abandoned.
            if (!self.exitRequested && !self.failed)
                writeLiteral(2, "djs: teardown: loop still active; not freed\n");
        }
        else
        {
            int loopErr = uv_loop_close(self.loop);
            if (loopErr != 0)
            {
                writeLiteral(2, "djs: uv_loop_close failed: ");
                writeLiteral(2, uv_strerror(loopErr));
                writeLiteral(2, "\n");
                if (!self.exitRequested)
                    code = 70;
            }
            else
            {
                free(self.loop);
            }
        }
    }

    if (self.argv !is null)
    {
        for (int i = 0; i < self.argc; ++i)
            free(self.argv[i]);
        free(self.argv);
    }
    if (self.rootDir !is null)
        free(self.rootDir);
    if (self.entryFile !is null)
        free(self.entryFile);
    free(self);
    if (loopStuck)
    {
        // A blocked libuv worker still references a loop we deliberately did
        // not free. Returning through druntime shutdown with that thread alive
        // can hang, so leave the process directly; the OS reclaims everything.
        import core.sys.posix.unistd : _exit;
        _exit(code);
    }
    return code;
}

unittest
{
    RuntimeOptions opts;
    Runtime* rt = runtimeCreate(["djs", "-e", ""], opts);
    assert(rt !is null);
    JSValue result = jsUndefined();
    assert(runtimeEval(rt, "1 + 1", 5, "<unittest>", &result) == EvalResult.ok);
    int value = 0;
    assert(JS_ToInt32(rt.ctx, &value, result) == 0);
    assert(value == 2);
    JS_FreeValue(rt.ctx, result);
    assert(runtimeTeardown(rt) == 0);

    // Hot-path allocation counter: 1,000 timer create/clear cycles must not
    // allocate through the D GC. Warm up first so lazy one-time allocations
    // (exception tables, first eval) are outside the measured region.
    import core.memory : GC;
    Runtime* hot = runtimeCreate(["djs", "-e", ""], opts);
    assert(hot !is null);
    assert(runtimeInstallPrelude(hot));
    JSValue warm = jsUndefined();
    assert(runtimeEval(hot, "0", 1, "<unittest>", &warm) == EvalResult.ok);
    JS_FreeValue(hot.ctx, warm);
    const(char)* script = "for (let i = 0; i < 1000; i++) clearTimeout(setTimeout(() => {}, 1000));";
    size_t before = GC.stats.allocatedInCurrentThread;
    assert(runtimeEval(hot, script, strlen(script), "<unittest>", &warm) == EvalResult.ok);
    size_t after = GC.stats.allocatedInCurrentThread;
    JS_FreeValue(hot.ctx, warm);
    assert(after == before);
    assert(runtimeTeardown(hot) == 0);
}
