module djs.apis.stdio;

// process.stdin support. A 5 ms timer polls fd 0; data is only read once the
// JavaScript side starts the stream (a 'data' listener or resume()), so a
// script that never touches stdin does not consume the REPL's input.

import core.stdc.errno : EAGAIN, EINTR, EWOULDBLOCK, errno;
import core.stdc.stdlib : free, malloc;
import core.sys.posix.poll : POLLIN, poll, pollfd;
import core.sys.posix.sys.types : ssize_t;
import core.sys.posix.unistd : isatty, read;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.registry : CallbackSlot, registryAdd, registryLookup, registryRelease;
import djs.runtime : Runtime, guarded, runtimeOf, runtimeReportUncaught;

private struct StdinState
{
    Runtime* rt;
    uv_timer_t* timer;
    ulong cb;
    bool used;
}

private StdinState stdinState;

private extern(C) void stdinTimerClose(uv_handle_t* h) nothrow @nogc { free(h); }

private void stdinStopState(Runtime* rt) @nogc nothrow
{
    StdinState* s = &stdinState;
    if (s.timer !is null)
    {
        uv_timer_stop(s.timer);
        uv_close(cast(uv_handle_t*) s.timer, &stdinTimerClose);
        s.timer = null;
    }
    if (s.cb != 0 && rt !is null)
        registryRelease(rt.ctx, &rt.registry, s.cb);
    s.cb = 0;
    s.used = false;
}

private void stdinDeliver(StdinState* s, int n, const(char)* buf) @nogc nothrow
{
    if (s.cb == 0 || s.rt is null) return;
    CallbackSlot* slot = registryLookup(&s.rt.registry, s.cb);
    if (slot is null) return;
    JSValue chunk = n <= 0 ? jsNull() : JS_NewStringLen(s.rt.ctx, buf, cast(size_t) n);
    JSValue[2] argv = [jsNull(), chunk];
    JSValue fn = JS_DupValue(s.rt.ctx, slot.fn);
    JSValue r = JS_Call(s.rt.ctx, fn, jsUndefined(), 2, argv.ptr);
    JS_FreeValue(s.rt.ctx, fn);
    JS_FreeValue(s.rt.ctx, chunk);
    if (jsIsException(r))
    {
        JS_FreeValue(s.rt.ctx, r);
        runtimeReportUncaught(s.rt, s.rt.ctx);
        stdinStopState(s.rt);
    }
    else
        JS_FreeValue(s.rt.ctx, r);
}

private extern(C) void stdinTimerCb(uv_timer_t* t) nothrow @nogc
{
    StdinState* s = cast(StdinState*) uv_handle_get_data(cast(uv_handle_t*) t);
    if (s is null || !s.used || s.cb == 0) return;
    pollfd p = void;
    p.fd = 0;
    p.events = POLLIN;
    int pr = poll(&p, 1, 0);
    if (pr <= 0) return;
    char[16384] buf = void;
    ssize_t n = read(0, buf.ptr, buf.length);
    if (n > 0)
    {
        stdinDeliver(s, cast(int) n, buf.ptr);
        return;
    }
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        return;
    // EOF or a hard error ends the stream, matching Node's Readable.
    stdinDeliver(s, 0, null);
    stdinStopState(s.rt);
}

private extern(C) JSValue jsStdinStartImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    if (argc < 1 || !JS_IsFunction(ctx, argv[0]))
        return throwTypeError(ctx, "stdinStart requires a callback");
    Runtime* rt = runtimeOf(ctx);
    if (rt is null) return throwInternalError(ctx, "no runtime");
    StdinState* s = &stdinState;
    if (s.used)
    {
        if (s.cb != 0) registryRelease(rt.ctx, &rt.registry, s.cb);
        s.cb = registryAdd(ctx, &rt.registry, argv[0], null);
        return jsUndefined();
    }
    if (s.timer is null)
    {
        s.timer = cast(uv_timer_t*) malloc(uv_handle_size(UV_TIMER));
        if (s.timer is null) return throwInternalError(ctx, "out of memory");
        if (uv_timer_init(rt.loop, s.timer) != 0)
        {
            free(s.timer);
            s.timer = null;
            return throwInternalError(ctx, "timer init failed");
        }
        uv_handle_set_data(cast(uv_handle_t*) s.timer, s);
    }
    s.cb = registryAdd(ctx, &rt.registry, argv[0], null);
    if (s.cb == 0) return throwInternalError(ctx, "out of memory");
    s.rt = rt;
    s.used = true;
    if (uv_timer_start(s.timer, &stdinTimerCb, 5, 5) != 0)
    {
        registryRelease(ctx, &rt.registry, s.cb);
        s.cb = 0;
        s.used = false;
        return throwInternalError(ctx, "timer start failed");
    }
    return jsUndefined();
}
extern(C) JSValue jsStdinStart(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsStdinStartImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsStdinStopImpl(JSContext* ctx, JSValueConst, int argc,
                                          JSValueConst* argv) nothrow @nogc
{
    stdinStopState(runtimeOf(ctx));
    return jsUndefined();
}
extern(C) JSValue jsStdinStop(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsStdinStopImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsStdinIsTTY(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    return jsInt(isatty(0) == 1 ? 1 : 0);
}
extern(C) JSValue jsStdinIsTTYFn(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsStdinIsTTY(ctx, thisVal, argc, argv); }

// tty.isatty(fd) for any descriptor: CLI colour detection needs fd 1 and 2.
private extern(C) JSValue jsStdioIsattyFdImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    int fd = 0;
    if (argc > 0 && JS_ToInt32(ctx, &fd, argv[0]) < 0)
        return jsException();
    if (fd < 0 || fd > 1024)
        return jsInt(0);
    return jsInt(isatty(fd) == 1 ? 1 : 0);
}
extern(C) JSValue jsStdioIsattyFd(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsStdioIsattyFdImpl(ctx, thisVal, argc, argv); }

void stdioCloseAll(Runtime* self) @nogc nothrow
{
    if (self is null) return;
    if (stdinState.used && stdinState.rt is self)
        stdinStopState(self);
}

bool installStdio(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "stdinStart", &jsStdinStart, 1)
        && addNativeFunction(ctx, obj, "stdinStop", &jsStdinStop, 0)
        && addNativeFunction(ctx, obj, "isTTY", &jsStdinIsTTYFn, 0)
        && addNativeFunction(ctx, obj, "isattyFd", &jsStdioIsattyFd, 1);
    if (!ok || JS_SetPropertyStr(ctx, djs, "stdio", obj) < 0)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return true;
}
