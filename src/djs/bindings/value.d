module djs.bindings.value;

import core.stdc.string : memcpy, strlen;
import core.stdc.stdlib : malloc, free;
import djs.bindings.quickjs;

// One owner per JSValue. A ScopedValue owns exactly the reference it was
// constructed with; it frees that reference on scope exit. It is deliberately
// non-copyable because D has no move constructor and a blit copy would free
// the same reference twice. Move it with core.lifetime.move and pass it by ref.
struct ScopedValue
{
    JSContext* ctx;
    JSValue v;

    @disable this(this);

    this(JSContext* c, JSValue value) @nogc nothrow
    {
        ctx = c;
        v = value;
    }

    ~this() @nogc nothrow
    {
        if (ctx !is null)
            JS_FreeValue(ctx, v);
    }

    JSValue release() @nogc nothrow
    {
        JSValue moved = v;
        v = jsUndefined();
        return moved;
    }
}

JSValue jsException() @nogc nothrow
{
    JSValue v;
    v.u.int32 = 0;
    v.tag = JS_TAG_EXCEPTION;
    return v;
}

// C variadics cannot receive D dynamic arrays, so every thrown message goes
// through these wrappers with an explicit %s format and a NUL-terminated
// pointer. The format string is never user-controlled.
JSValue throwTypeError(JSContext* ctx, const(char)* msg) @nogc nothrow
{
    return JS_ThrowTypeError(ctx, cast(const(char)*) "%s", msg);
}

JSValue throwRangeError(JSContext* ctx, const(char)* msg) @nogc nothrow
{
    return JS_ThrowRangeError(ctx, cast(const(char)*) "%s", msg);
}

JSValue throwInternalError(JSContext* ctx, const(char)* msg) @nogc nothrow
{
    return JS_ThrowInternalError(ctx, cast(const(char)*) "%s", msg);
}

bool toStringView(JSContext* ctx, JSValueConst val, const(char)** dest,
                  size_t* len) @nogc nothrow
{
    size_t n = 0;
    const(char)* p = JS_ToCStringLen2(ctx, &n, val, false);
    if (p is null)
        return false;
    *dest = p;
    *len = n;
    return true;
}

bool toInt32(JSContext* ctx, JSValueConst val, int* dest) @nogc nothrow
{
    return JS_ToInt32(ctx, dest, val) == 0;
}

bool toFloat64(JSContext* ctx, JSValueConst val, double* dest) @nogc nothrow
{
    return JS_ToFloat64(ctx, dest, val) == 0;
}

JSValue newString(JSContext* ctx, const(char)* s) @nogc nothrow
{
    if (s is null)
        return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, s, strlen(s));
}

// JS_SetPropertyStr consumes `val` on success and on failure. QuickJS-NG
// returns 1 on success, 0 when the property could not be set, and -1 with a
// pending exception. Only a positive result is success.
bool setProp(JSContext* ctx, JSValueConst obj, const(char)* name,
             JSValue val) @nogc nothrow
{
    return JS_SetPropertyStr(ctx, obj, name, val) > 0;
}

// JS_SetPropertyUint32 also consumes `val` and has the same result convention.
bool setIndex(JSContext* ctx, JSValueConst obj, uint idx, JSValue val) @nogc nothrow
{
    return JS_SetPropertyUint32(ctx, obj, idx, val) > 0;
}

bool addNativeFunction(JSContext* ctx, JSValueConst obj, const(char)* name,
                       JSCFunction fn, int length) @nogc nothrow
{
    JSValue f = JS_NewCFunction2(ctx, fn, name, length, JS_CFUNC_generic, 0);
    if (jsIsException(f))
        return false;
    // JS_SetPropertyStr consumes f on both success and failure. QuickJS-NG
    // returns a positive value on success (not zero).
    return JS_SetPropertyStr(ctx, obj, name, f) > 0;
}

// Build an Error object with Node-shaped fields. Returns an owned value; on
// failure it returns JS_EXCEPTION with the pending exception left in place.
JSValue makeError(JSContext* ctx, const(char)* message, const(char)* code,
                  const(char)* path, const(char)* syscall) @nogc nothrow
{
    JSValue err = JS_NewError(ctx);
    if (jsIsException(err))
        return err;
    if (message !is null && !setProp(ctx, err, "message", newString(ctx, message)))
    {
        JS_FreeValue(ctx, err);
        if (!JS_HasException(ctx))
            throwInternalError(ctx, "out of memory");
        return jsException();
    }
    if (code !is null)
        setProp(ctx, err, "code", newString(ctx, code));
    if (path !is null)
        setProp(ctx, err, "path", newString(ctx, path));
    if (syscall !is null)
        setProp(ctx, err, "syscall", newString(ctx, syscall));
    return err;
}

// Throw an owned error object. JS_Throw takes ownership of `err`.
JSValue throwError(JSContext* ctx, JSValue err) @nogc nothrow
{
    return JS_Throw(ctx, err);
}

char* dupCString(const(char)* s) @nogc nothrow
{
    if (s is null)
        return null;
    size_t n = strlen(s);
    char* p = cast(char*) malloc(n + 1);
    if (p is null)
        return null;
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}

void freeCString(char* s) @nogc nothrow
{
    free(s);
}


@nogc nothrow unittest
{
    // Copying a ScopedValue would double-free the owned reference.
    static assert(!__traits(compiles, {
        ScopedValue a;
        ScopedValue b = a;
    }));
}
