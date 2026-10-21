module djs.apis.timers;

import core.stdc.stdlib : calloc, free, malloc;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.loop.libuv;
import djs.registry;
import djs.runtime : Runtime, guarded, runtimeOf, runtimeReportUncaught;

// A timer owns one initialized uv_timer_t and one registry slot. Clearing a
// timer stops the handle and returns the state to a free list; handles are
// only closed during teardown. This bounds native memory for create/clear
// churn inside a single turn (close callbacks do not run until the loop turns).
struct TimerState
{
    uv_timer_t* handle;
    Runtime* rt;
    ulong id;
    ulong delay;
    ulong repeat;
    bool closing;
    TimerState* prev;
    TimerState* next;
    TimerState* freeNext;
}

private TimerState* timerHeadOf(Runtime* self) @nogc nothrow
{
    return cast(TimerState*) self.timerHead;
}

private void setTimerHead(Runtime* self, TimerState* head) @nogc nothrow
{
    self.timerHead = cast(void*) head;
}

private void linkTimer(Runtime* self, TimerState* state) @nogc nothrow
{
    TimerState* head = timerHeadOf(self);
    state.prev = null;
    state.next = head;
    if (head !is null)
        head.prev = state;
    setTimerHead(self, state);
}

private void unlinkTimer(Runtime* self, TimerState* state) @nogc nothrow
{
    if (state.prev !is null)
        state.prev.next = state.next;
    else
        setTimerHead(self, state.next);
    if (state.next !is null)
        state.next.prev = state.prev;
    state.prev = null;
    state.next = null;
}

private extern(C) void onTimerClosed(uv_handle_t* h) nothrow @nogc
{
    TimerState* state = cast(TimerState*) uv_handle_get_data(h);
    if (state is null)
    {
        free(h);
        return;
    }
    free(state.handle);
    free(state);
}

private void pushFree(Runtime* self, TimerState* state) @nogc nothrow
{
    state.freeNext = cast(TimerState*) self.timerFree;
    self.timerFree = cast(void*) state;
}

private TimerState* popFree(Runtime* self) @nogc nothrow
{
    TimerState* state = cast(TimerState*) self.timerFree;
    if (state is null)
        return null;
    self.timerFree = cast(void*) state.freeNext;
    state.freeNext = null;
    return state;
}

private TimerState* acquireTimer(Runtime* self) @nogc nothrow
{
    TimerState* state = popFree(self);
    if (state !is null)
        return state;
    state = cast(TimerState*) calloc(1, TimerState.sizeof);
    if (state is null)
        return null;
    state.handle = cast(uv_timer_t*) malloc(uv_handle_size(UV_TIMER));
    if (state.handle is null)
    {
        free(state);
        return null;
    }
    int rc = uv_timer_init(self.loop, state.handle);
    if (rc != 0)
    {
        free(state.handle);
        free(state);
        return null;
    }
    state.rt = self;
    uv_handle_set_data(cast(uv_handle_t*) state.handle, state);
    return state;
}

// Stop a timer and release its JS reference. A stopped handle is reusable, so
// it goes on the free list unless teardown is closing everything.
private void retireTimer(Runtime* self, TimerState* state) @nogc nothrow
{
    if (state.closing)
        return;
    if (state.id != 0)
    {
        registryRelease(self.ctx, &self.registry, state.id);
        state.id = 0;
    }
    unlinkTimer(self, state);
    if (state.handle !is null)
        uv_timer_stop(state.handle);
    if (self.shuttingDown)
    {
        state.closing = true;
        if (state.handle !is null)
            uv_close(cast(uv_handle_t*) state.handle, &onTimerClosed);
    }
    else
    {
        pushFree(self, state);
    }
}

private ulong parseTimerId(JSContext* ctx, JSValueConst val, bool* ok) @nogc nothrow
{
    *ok = false;
    long v = 0;
    if (jsIsBigInt(val))
    {
        if (JS_ToBigInt64(ctx, &v, val) != 0)
            return 0;
    }
    else
    {
        double d = 0;
        if (!toFloat64(ctx, val, &d) || !(d >= 1) || d > 9.0e18 || d != d)
            return 0;
        v = cast(long) d;
        if (cast(double) v != d)
            return 0;
    }
    if (v <= 0)
        return 0;
    *ok = true;
    return cast(ulong) v;
}

private ulong clampDelay(double d) @nogc nothrow
{
    // Node clamps delays below 1 ms, and values above 2^31-1, to 1 ms.
    if (!(d >= 1.0) || d > 2147483647.0)
        return 1;
    return cast(ulong) d;
}

private extern(C) void onTimer(uv_timer_t* h) nothrow @nogc
{
    TimerState* state = cast(TimerState*) uv_handle_get_data(cast(uv_handle_t*) h);
    if (state is null || state.rt is null || state.closing || state.id == 0)
        return;
    Runtime* self = state.rt;
    if (self.shuttingDown || self.failed || self.exitRequested)
        return;
    CallbackSlot* slot = registryLookup(&self.registry, state.id);
    if (slot is null)
    {
        retireTimer(self, state);
        return;
    }

    ulong firedId = state.id;
    // Dup before the call: the callback is allowed to clear itself, which
    // releases the registry's reference while JS is still executing it. The
    // state itself may also be recycled by a new timer in the same callback,
    // so only the id identifies the timer we fired.
    JSValue fn = JS_DupValue(self.ctx, slot.fn);
    JSValue result = JS_Call(self.ctx, fn, jsUndefined(), 0, null);
    JS_FreeValue(self.ctx, fn);
    if (jsIsException(result))
    {
        runtimeReportUncaught(self, self.ctx);
        JS_FreeValue(self.ctx, result);
        return;
    }
    JS_FreeValue(self.ctx, result);

    if (!state.closing && state.id == firedId && state.repeat == 0)
        retireTimer(self, state);
}

private extern(C) JSValue jsTimerStartImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || self.shuttingDown)
        return throwInternalError(ctx, "runtime is shutting down");
    if (argc < 3 || !JS_IsFunction(ctx, argv[2]))
        return throwTypeError(ctx, "timer callback must be a function");

    double delayArg = 1;
    if (!toFloat64(ctx, argv[0], &delayArg))
        return jsException();
    ulong delay = clampDelay(delayArg);
    int repeatArg = JS_ToBool(ctx, argv[1]);
    if (repeatArg < 0)
        return jsException();
    ulong repeat = repeatArg != 0 ? delay : 0;

    TimerState* state = acquireTimer(self);
    if (state is null)
        return throwInternalError(ctx, "out of memory");
    state.delay = delay;
    state.repeat = repeat;
    state.closing = false;

    ulong id = registryAdd(ctx, &self.registry, argv[2], state);
    if (id == 0)
    {
        pushFree(self, state);
        return throwInternalError(ctx, "timer registry exhausted");
    }
    state.id = id;
    linkTimer(self, state);

    int rc = uv_timer_start(state.handle, &onTimer, delay, repeat);
    if (rc != 0)
    {
        retireTimer(self, state);
        return throwInternalError(ctx, uv_strerror(rc));
    }
    // 64-bit ids are published as BigInt: the (generation, index) pair cannot
    // round through a double.
    return JS_NewBigInt64(ctx, cast(long) id);
}

extern(C) JSValue jsTimerStart(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsTimerStartImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsTimerClearImpl(JSContext* ctx, JSValueConst, int argc,
                                           JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || argc < 1)
        return jsUndefined();
    bool ok = false;
    ulong id = parseTimerId(ctx, argv[0], &ok);
    if (!ok)
        return jsUndefined();
    CallbackSlot* slot = registryLookup(&self.registry, id);
    if (slot is null)
        return jsUndefined();
    TimerState* state = cast(TimerState*) slot.user;
    if (state !is null)
        retireTimer(self, state);
    return jsUndefined();
}

extern(C) JSValue jsTimerClear(JSContext* ctx, JSValueConst thisVal, int argc,
                               JSValueConst* argv) nothrow @nogc
{
    return guarded!jsTimerClearImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsTimerRefImpl(JSContext* ctx, JSValueConst, int argc,
                                         JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || argc < 2)
        return jsUndefined();
    bool ok = false;
    ulong id = parseTimerId(ctx, argv[0], &ok);
    if (!ok)
        return jsUndefined();
    int wantRef = JS_ToBool(ctx, argv[1]);
    if (wantRef < 0)
        return jsException();
    TimerState* state = cast(TimerState*) registryUser(&self.registry, id);
    if (state !is null && state.handle !is null && !state.closing)
    {
        if (wantRef != 0)
            uv_ref(cast(uv_handle_t*) state.handle);
        else
            uv_unref(cast(uv_handle_t*) state.handle);
    }
    return jsUndefined();
}

extern(C) JSValue jsTimerRef(JSContext* ctx, JSValueConst thisVal, int argc,
                             JSValueConst* argv) nothrow @nogc
{
    return guarded!jsTimerRefImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsTimerHasRefImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || argc < 1)
        return jsBool(false);
    bool ok = false;
    ulong id = parseTimerId(ctx, argv[0], &ok);
    if (!ok)
        return jsBool(false);
    TimerState* state = cast(TimerState*) registryUser(&self.registry, id);
    if (state is null || state.handle is null || state.closing)
        return jsBool(false);
    return jsBool(uv_has_ref(cast(uv_handle_t*) state.handle) != 0);
}

extern(C) JSValue jsTimerHasRef(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsTimerHasRefImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsTimerRefreshImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || argc < 2)
        return jsUndefined();
    bool ok = false;
    ulong id = parseTimerId(ctx, argv[0], &ok);
    if (!ok)
        return jsUndefined();
    double delayArg = 1;
    if (!toFloat64(ctx, argv[1], &delayArg))
        return jsException();
    ulong delay = clampDelay(delayArg);
    TimerState* state = cast(TimerState*) registryUser(&self.registry, id);
    if (state !is null && !state.closing && state.handle !is null)
    {
        uv_timer_start(state.handle, &onTimer, delay, state.repeat != 0 ? delay : 0);
        state.delay = delay;
    }
    return jsUndefined();
}

extern(C) JSValue jsTimerRefresh(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{
    return guarded!jsTimerRefreshImpl(ctx, thisVal, argc, argv);
}

bool installTimers(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;
    bool ok = addNativeFunction(ctx, obj, "start", &jsTimerStart, 3)
        && addNativeFunction(ctx, obj, "clear", &jsTimerClear, 1)
        && addNativeFunction(ctx, obj, "ref", &jsTimerRef, 2)
        && addNativeFunction(ctx, obj, "hasRef", &jsTimerHasRef, 1)
        && addNativeFunction(ctx, obj, "refresh", &jsTimerRefresh, 2);
    if (!ok)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return JS_SetPropertyStr(ctx, djs, "timer", obj) > 0;
}

// Close every timer during teardown: live states first, then the recyclable
// pool. The handle's close callback is the only place memory is freed.
void timersCloseAll(Runtime* self) @nogc nothrow
{
    TimerState* state = timerHeadOf(self);
    while (state !is null)
    {
        TimerState* next = state.next;
        retireTimer(self, state);
        state = next;
    }
    state = cast(TimerState*) self.timerFree;
    self.timerFree = null;
    while (state !is null)
    {
        TimerState* next = state.freeNext;
        state.freeNext = null;
        state.closing = true;
        if (state.handle !is null && uv_is_closing(cast(uv_handle_t*) state.handle) == 0)
            uv_close(cast(uv_handle_t*) state.handle, &onTimerClosed);
        state = next;
    }
}
