module djs.apis.signals;

// Receiving POSIX signals through libuv. One uv_signal_t per signum; the
// JavaScript prelude keeps the handler list and routes names to numbers.
// process.kill() is intentionally not implemented: sending signals to other
// processes is a separate capability from receiving them, and child_process
// already owns process creation.

import core.stdc.stdlib : free, malloc;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.registry : CallbackSlot, registryAdd, registryLookup, registryRelease;
import djs.runtime : Runtime, guarded, runtimeOf, runtimeReportUncaught;

private enum int maxSignals = 8;

private struct SignalEntry
{
    bool used;
    int signum;
    uv_signal_t* handle;
    ulong cb;
    Runtime* rt;
}

private SignalEntry[maxSignals] entries;

private extern(C) void signalClose(uv_handle_t* h) nothrow @nogc { free(h); }

private extern(C) void signalCb(uv_signal_t* h, int signum) nothrow @nogc
{
    SignalEntry* e = cast(SignalEntry*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (e is null || !e.used || e.rt is null || e.cb == 0)
        return;
    CallbackSlot* slot = registryLookup(&e.rt.registry, e.cb);
    if (slot is null)
        return;
    JSValue fn = JS_DupValue(e.rt.ctx, slot.fn);
    JSValue[1] argv = [jsInt(signum)];
    JSValue r = JS_Call(e.rt.ctx, fn, jsUndefined(), 1, argv.ptr);
    JS_FreeValue(e.rt.ctx, fn);
    if (jsIsException(r))
    {
        JS_FreeValue(e.rt.ctx, r);
        runtimeReportUncaught(e.rt, e.rt.ctx);
    }
    else
        JS_FreeValue(e.rt.ctx, r);
}

private SignalEntry* findSignal(int signum) @nogc nothrow
{
    foreach (ref e; entries)
        if (e.used && e.signum == signum)
            return &e;
    return null;
}

private extern(C) JSValue jsSignalOnImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    int signum = 0;
    if (argc < 2 || !toInt32(ctx, argv[0], &signum) || !JS_IsFunction(ctx, argv[1]))
        return throwTypeError(ctx, "signal.on requires (signum, callback)");
    if (signum < 1 || signum > 64)
        return throwRangeError(ctx, "invalid signal");
    SignalEntry* e = findSignal(signum);
    if (e !is null)
    {
        if (e.cb != 0) registryRelease(e.rt.ctx, &e.rt.registry, e.cb);
        e.cb = registryAdd(ctx, &e.rt.registry, argv[1], null);
        if (e.cb == 0) return throwInternalError(ctx, "out of memory");
        return jsUndefined();
    }
    int slot = -1;
    foreach (i; 0 .. maxSignals) if (!entries[i].used) { slot = cast(int) i; break; }
    if (slot < 0)
        return throwInternalError(ctx, "signal table exhausted");
    Runtime* rt = runtimeOf(ctx);
    if (rt is null) return throwInternalError(ctx, "no runtime");
    uv_signal_t* h = cast(uv_signal_t*) malloc(uv_handle_size(UV_SIGNAL));
    if (h is null) return throwInternalError(ctx, "out of memory");
    if (uv_signal_init(rt.loop, h) != 0)
    {
        free(h);
        return throwInternalError(ctx, "signal init failed");
    }
    SignalEntry* ne = &entries[slot];
    ne.used = true;
    ne.signum = signum;
    ne.handle = h;
    ne.rt = rt;
    ne.cb = registryAdd(ctx, &rt.registry, argv[1], null);
    if (ne.cb == 0)
    {
        uv_close(cast(uv_handle_t*) h, &signalClose);
        ne.used = false;
        return throwInternalError(ctx, "out of memory");
    }
    uv_handle_set_data(cast(uv_handle_t*) h, ne);
    if (uv_signal_start(h, &signalCb, signum) != 0)
    {
        registryRelease(ctx, &rt.registry, ne.cb);
        ne.cb = 0;
        uv_close(cast(uv_handle_t*) h, &signalClose);
        ne.used = false;
        return throwInternalError(ctx, "signal start failed");
    }
    // A signal listener observes the process, it does not keep it alive: Node
    // exits normally with a SIGTERM handler installed.
    uv_unref(cast(uv_handle_t*) h);
    return jsUndefined();
}
extern(C) JSValue jsSignalOn(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSignalOnImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsSignalOffImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    int signum = 0;
    if (argc < 1 || !toInt32(ctx, argv[0], &signum))
        return throwTypeError(ctx, "signal.off requires a signum");
    SignalEntry* e = findSignal(signum);
    if (e is null) return jsUndefined();
    if (e.handle !is null)
    {
        uv_signal_stop(e.handle);
        uv_close(cast(uv_handle_t*) e.handle, &signalClose);
        e.handle = null;
    }
    if (e.cb != 0 && e.rt !is null)
        registryRelease(e.rt.ctx, &e.rt.registry, e.cb);
    e.cb = 0;
    e.used = false;
    e.rt = null;
    return jsUndefined();
}
extern(C) JSValue jsSignalOff(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsSignalOffImpl(ctx, thisVal, argc, argv); }

void signalsCloseAll(Runtime* self) @nogc nothrow
{
    if (self is null) return;
    foreach (ref e; entries)
    {
        if (!e.used || e.rt !is self) continue;
        if (e.handle !is null)
        {
            uv_signal_stop(e.handle);
            uv_close(cast(uv_handle_t*) e.handle, &signalClose);
            e.handle = null;
        }
        if (e.cb != 0) registryRelease(self.ctx, &self.registry, e.cb);
        e.cb = 0;
        e.used = false;
        e.rt = null;
    }
}

bool installSignals(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "on", &jsSignalOn, 2)
        && addNativeFunction(ctx, obj, "off", &jsSignalOff, 1);
    if (!ok || JS_SetPropertyStr(ctx, djs, "signal", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
