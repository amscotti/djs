module djs.apis.console;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.runtime : Runtime, guarded, writeFd;

// __djs.console.write(fd, string). Formatting lives in the JavaScript prelude;
// this primitive only performs an unbuffered write(2).
private extern(C) JSValue jsConsoleWriteImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv) nothrow @nogc
{
    if (argc < 2)
        return throwTypeError(ctx, "console.write requires (fd, string)");
    int fd = 1;
    if (!toInt32(ctx, argv[0], &fd))
        return jsException();
    if (fd != 1 && fd != 2)
        return throwRangeError(ctx, "console.write fd must be 1 or 2");
    const(char)* text = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[1], &text, &len))
        return jsException();
    scope(exit) JS_FreeCString(ctx, text);
    writeFd(fd, text, len);
    return jsUndefined();
}

extern(C) JSValue jsConsoleWrite(JSContext* ctx, JSValueConst thisVal, int argc,
                                 JSValueConst* argv) nothrow @nogc
{
    return guarded!jsConsoleWriteImpl(ctx, thisVal, argc, argv);
}

bool installConsole(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue obj = JS_NewObject(ctx);
    if (jsIsException(obj))
        return false;
    bool ok = addNativeFunction(ctx, obj, "write", &jsConsoleWrite, 2);
    if (!ok)
    {
        JS_FreeValue(ctx, obj);
        return false;
    }
    return JS_SetPropertyStr(ctx, djs, "console", obj) > 0;
}
