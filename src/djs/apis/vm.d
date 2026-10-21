module djs.apis.vm;

import core.stdc.string : strlen;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.runtime : Runtime, guarded, runtimeOf;

private struct vm_undefined_stub;

extern(C)
{
    JSValue JS_JSONStringify(JSContext* ctx, JSValueConst obj, JSValueConst replacer, JSValueConst space) nothrow @nogc;
}

private extern(C) JSValue jsVmRunNewImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 3 || !jsIsString(argv[0]) || !jsIsString(argv[1]) || !jsIsString(argv[2]))
        return throwTypeError(ctx, "vm.runInNewContext requires (source, sandboxJson, filename)");
    const(char)* src = null; size_t srcLen = 0;
    const(char)* sandboxJson = null; size_t sandboxLen = 0;
    const(char)* filename = null; size_t filenameLen = 0;
    if (!toStringView(ctx, argv[0], &src, &srcLen)) return jsException();
    if (!toStringView(ctx, argv[1], &sandboxJson, &sandboxLen)) { JS_FreeCString(ctx, src); return jsException(); }
    if (!toStringView(ctx, argv[2], &filename, &filenameLen)) { JS_FreeCString(ctx, src); JS_FreeCString(ctx, sandboxJson); return jsException(); }
    scope(exit) { JS_FreeCString(ctx, src); JS_FreeCString(ctx, sandboxJson); JS_FreeCString(ctx, filename); }

    Runtime* rt = runtimeOf(ctx);
    if (rt is null) return throwInternalError(ctx, "no runtime");
    JSContext* nctx = JS_NewContext(rt.rt);
    if (nctx is null) return throwInternalError(ctx, "cannot create VM context");
    scope(exit) JS_FreeContext(nctx);

    JSValue sandbox = JS_ParseJSON(nctx, sandboxJson, sandboxLen, "<sandbox>");
    if (jsIsException(sandbox)) return throwError(ctx, makeError(ctx, "invalid VM sandbox", "ERR_VM_SANDBOX", null, "vm"));
    scope(exit) JS_FreeValue(nctx, sandbox);

    JSValue fn = JS_Eval(nctx, src, srcLen, filename, 0);
    if (jsIsException(fn))
    {
        JSValue ex = JS_GetException(nctx);
        size_t mlen = 0;
        const(char)* msg = JS_ToCStringLen2(nctx, &mlen, ex, false);
        JSValue err = makeError(ctx, msg is null ? "VM script failed" : msg, "ERR_VM_SCRIPT", null, "vm");
        if (msg !is null) JS_FreeCString(nctx, msg);
        JS_FreeValue(nctx, ex);
        return throwError(ctx, err);
    }
    scope(exit) JS_FreeValue(nctx, fn);

    JSValue result = JS_Call(nctx, fn, jsUndefined(), 1, &sandbox);
    if (jsIsException(result))
    {
        JSValue ex = JS_GetException(nctx);
        size_t mlen = 0;
        const(char)* msg = JS_ToCStringLen2(nctx, &mlen, ex, false);
        JSValue err = makeError(ctx, msg is null ? "VM script threw" : msg, "ERR_VM_SCRIPT", null, "vm");
        if (msg !is null) JS_FreeCString(nctx, msg);
        JS_FreeValue(nctx, ex);
        return throwError(ctx, err);
    }
    scope(exit) JS_FreeValue(nctx, result);

    if (jsIsUndefined(result)) return jsUndefined();
    JSValue json = JS_JSONStringify(nctx, result, jsUndefined(), jsUndefined());
    if (jsIsException(json))
    {
        JS_FreeValue(nctx, JS_GetException(nctx));
        return throwError(ctx, makeError(ctx, "VM result is not serializable", "ERR_VM_RESULT", null, "vm"));
    }
    size_t jlen = 0;
    const(char)* str = JS_ToCStringLen2(nctx, &jlen, json, false);
    JS_FreeValue(nctx, json);
    if (str is null) return throwInternalError(ctx, "VM result conversion failed");
    scope(exit) JS_FreeCString(nctx, str);
    return JS_NewStringLen(ctx, str, jlen);
}
extern(C) JSValue jsVmRunNew(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsVmRunNewImpl(ctx, thisVal, argc, argv); }

private extern(C) JSValue jsVmRunThisImpl(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) nothrow @nogc
{
    if (argc < 2 || !jsIsString(argv[0]) || !jsIsString(argv[1]))
        return throwTypeError(ctx, "vm.runInThisContext requires (source, filename)");
    const(char)* src = null; size_t srcLen = 0;
    const(char)* filename = null; size_t filenameLen = 0;
    if (!toStringView(ctx, argv[0], &src, &srcLen)) return jsException();
    if (!toStringView(ctx, argv[1], &filename, &filenameLen)) { JS_FreeCString(ctx, src); return jsException(); }
    scope(exit) { JS_FreeCString(ctx, src); JS_FreeCString(ctx, filename); }
    JSValue r = JS_Eval(ctx, src, srcLen, filename, 0);
    if (jsIsException(r)) return r;
    return r;
}
extern(C) JSValue jsVmRunThis(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{ return guarded!jsVmRunThisImpl(ctx, thisVal, argc, argv); }

bool installVm(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj)) return false;
    bool ok = addNativeFunction(ctx, obj, "runNew", &jsVmRunNew, 3)
        && addNativeFunction(ctx, obj, "runThis", &jsVmRunThis, 2);
    if (!ok) { JS_FreeValue(ctx, obj); return false; }
    if (JS_SetPropertyStr(ctx, djs, "vm", obj) < 0) { JS_FreeValue(ctx, obj); return false; }
    return true;
}
