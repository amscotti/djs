module djs.modules.cjs;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memchr, memcpy, strcmp, strlen;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.modules.classify : ModuleKind;
import djs.modules.path : dirNameAlloc, neutraliseShebang, readFileAlloc;
import djs.modules.resolve : Resolved, resolveSpec;
import djs.runtime : Runtime, guarded, runtimeOf;

private JSValue throwModuleError(JSContext* ctx, const(char)* code,
                                 const(char)* message, const(char)* path) @nogc nothrow
{
    char* enriched = null;
    if (path !is null)
    {
        size_t ml = strlen(message), pl = strlen(path);
        enriched = cast(char*) malloc(ml + pl + 5);
        if (enriched !is null)
        {
            memcpy(enriched, message, ml);
            enriched[ml] = ' ';
            enriched[ml + 1] = '\'';
            memcpy(enriched + ml + 2, path, pl);
            enriched[ml + 2 + pl] = '\'';
            enriched[ml + 3 + pl] = 0;
        }
    }
    JSValue e = makeError(ctx, enriched !is null ? enriched : message, code, path, "require");
    free(enriched);
    if (jsIsException(e))
        return e;
    return throwError(ctx, e);
}

// The builtin objects live on the global scope (installed by the prelude);
// return a new reference to the requested one. `alias` is the internal djs:
// name from the classifier.
private JSValue builtinValue(JSContext* ctx, const(char)* builtin) @nogc nothrow
{
    JSValue global = JS_GetGlobalObject(ctx);
    if (jsIsException(global))
        return global;

    JSValue result;
    if (!strcmp(builtin, "djs:fs/promises"))
    {
        JSValue fs = JS_GetPropertyStr(ctx, global, "fs");
        if (!jsIsException(fs))
        {
            result = JS_GetPropertyStr(ctx, fs, "promises");
            JS_FreeValue(ctx, fs);
        }
        else
            result = fs;
    }
    else if (!strcmp(builtin, "djs:assert"))
        result = JS_GetPropertyStr(ctx, global, "assert");
    else if (!strcmp(builtin, "djs:assert_strict"))
        result = JS_GetPropertyStr(ctx, global, "assert_strict");
    else if (!strcmp(builtin, "djs:module"))
        result = JS_GetPropertyStr(ctx, global, "nodeModule");
    else if (!strcmp(builtin, "djs:stream_promises"))
        result = JS_GetPropertyStr(ctx, global, "stream_promises");
    else if (!strcmp(builtin, "djs:stream_consumers"))
        result = JS_GetPropertyStr(ctx, global, "streamConsumers");
    else if (!strcmp(builtin, "djs:fs"))
        result = JS_GetPropertyStr(ctx, global, "fs");
    else if (!strcmp(builtin, "djs:path"))
        result = JS_GetPropertyStr(ctx, global, "path");
    else if (!strcmp(builtin, "djs:path_win32") || !strcmp(builtin, "djs:path_posix"))
    {
        // Node exposes path/win32 and path/posix as builtin subpaths.
        JSValue p = JS_GetPropertyStr(ctx, global, "path");
        if (jsIsException(p))
            result = p;
        else
        {
            result = JS_GetPropertyStr(ctx, p, !strcmp(builtin, "djs:path_win32") ? "win32" : "posix");
            JS_FreeValue(ctx, p);
        }
    }
    else if (!strcmp(builtin, "djs:os"))
        result = JS_GetPropertyStr(ctx, global, "os");
    else if (!strcmp(builtin, "djs:events"))
        result = JS_GetPropertyStr(ctx, global, "events");
    else if (!strcmp(builtin, "djs:stream"))
        result = JS_GetPropertyStr(ctx, global, "stream");
    else if (!strcmp(builtin, "djs:url"))
        result = JS_GetPropertyStr(ctx, global, "url");
    else if (!strcmp(builtin, "djs:util"))
        result = JS_GetPropertyStr(ctx, global, "util");
    else if (!strcmp(builtin, "djs:timers/promises"))
        result = JS_GetPropertyStr(ctx, global, "timersPromises");
    else if (!strcmp(builtin, "djs:buffer"))
        result = JS_GetPropertyStr(ctx, global, "buffer");
    else if (!strcmp(builtin, "djs:net"))
        result = JS_GetPropertyStr(ctx, global, "net");
    else if (!strcmp(builtin, "djs:dns"))
        result = JS_GetPropertyStr(ctx, global, "dns");
    else if (!strcmp(builtin, "djs:dns_promises"))
        result = JS_GetPropertyStr(ctx, global, "dns_promises");
    else if (!strcmp(builtin, "djs:http"))
        result = JS_GetPropertyStr(ctx, global, "http");
    else if (!strcmp(builtin, "djs:https"))
        result = JS_GetPropertyStr(ctx, global, "https");
    else if (!strcmp(builtin, "djs:tls"))
        result = JS_GetPropertyStr(ctx, global, "tls");
    else if (!strcmp(builtin, "djs:child_process"))
        result = JS_GetPropertyStr(ctx, global, "child_process");
    else if (!strcmp(builtin, "djs:crypto"))
        result = JS_GetPropertyStr(ctx, global, "crypto");
    else if (!strcmp(builtin, "djs:zlib"))
        result = JS_GetPropertyStr(ctx, global, "zlib");
    else if (!strcmp(builtin, "djs:dgram"))
        result = JS_GetPropertyStr(ctx, global, "dgram");
    else if (!strcmp(builtin, "djs:readline"))
        result = JS_GetPropertyStr(ctx, global, "readline");
    else if (!strcmp(builtin, "djs:readline_promises"))
        result = JS_GetPropertyStr(ctx, global, "readlinePromises");
    else if (!strcmp(builtin, "djs:worker_threads"))
        result = JS_GetPropertyStr(ctx, global, "worker_threads");
    else if (!strcmp(builtin, "djs:tty"))
        result = JS_GetPropertyStr(ctx, global, "tty");
    else if (!strcmp(builtin, "djs:querystring"))
        result = JS_GetPropertyStr(ctx, global, "querystring");
    else if (!strcmp(builtin, "djs:string_decoder"))
        result = JS_GetPropertyStr(ctx, global, "string_decoder");
    else if (!strcmp(builtin, "djs:perf_hooks"))
        result = JS_GetPropertyStr(ctx, global, "perf_hooks");
    else if (!strcmp(builtin, "djs:diagnostics_channel"))
        result = JS_GetPropertyStr(ctx, global, "diagnostics_channel");
    else if (!strcmp(builtin, "djs:trace_events"))
        result = JS_GetPropertyStr(ctx, global, "trace_events");
    else if (!strcmp(builtin, "djs:cluster"))
        result = JS_GetPropertyStr(ctx, global, "cluster");
    else if (!strcmp(builtin, "djs:timers"))
        result = JS_GetPropertyStr(ctx, global, "timers");
    else if (!strcmp(builtin, "djs:vm"))
        result = JS_GetPropertyStr(ctx, global, "vm");
    else if (!strcmp(builtin, "djs:stream_web"))
        result = JS_GetPropertyStr(ctx, global, "stream_web");
    else if (!strcmp(builtin, "djs:ws"))
        result = JS_GetPropertyStr(ctx, global, "ws");
    else if (!strcmp(builtin, "djs:http2"))
        result = JS_GetPropertyStr(ctx, global, "http2");
    else if (!strcmp(builtin, "djs:v8"))
        result = JS_GetPropertyStr(ctx, global, "v8");
    else
        result = JS_GetPropertyStr(ctx, global, "process");
    JS_FreeValue(ctx, global);
    return result;
}

private JSValue readJson(Runtime* self, const(char)* canonical) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(canonical, &src, &len, &err))
        return throwModuleError(ctx, "MODULE_NOT_FOUND", "cannot read module", canonical);
    JSValue v = JS_ParseJSON(ctx, src, len, canonical);
    free(src);
    return v;
}

// Drop a cache entry so the next require() re-executes instead of returning a
// partially built exports object. `undefined` is the miss marker in cjsLoad.
private void evict(Runtime* self, const(char)* canonical) @nogc nothrow
{
    JS_SetPropertyStr(self.ctx, self.requireCache, canonical, jsUndefined());
}

// Execute a CommonJS module and return its `module.exports` (owned).
JSValue cjsLoad(Runtime* self, const(char)* canonical, bool asMain = false) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    JSValue cached = JS_GetPropertyStr(ctx, self.requireCache, canonical);
    if (jsIsException(cached))
        return cached;
    if (!jsIsUndefined(cached))
    {
        JSValue exports = JS_GetPropertyStr(ctx, cached, "exports");
        JS_FreeValue(ctx, cached);
        return exports;
    }
    JS_FreeValue(ctx, cached);

    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(canonical, &src, &len, &err))
        return throwModuleError(ctx, "MODULE_NOT_FOUND", "cannot read module", canonical);

    // Neutralise in place rather than offsetting: a byte-offset shift moves
    // every reported line and column by the length of the shebang.
    neutraliseShebang(src, len);
    size_t codeOff = 0;

    char* dir = dirNameAlloc(canonical);
    if (dir is null)
    {
        free(src);
        return throwInternalError(ctx, "out of memory");
    }

    JSValue mod = JS_NewObject(ctx);
    if (jsIsException(mod))
    {
        free(src);
        free(dir);
        return mod;
    }
    JSValue exports = JS_NewObject(ctx);
    if (jsIsException(exports))
    {
        JS_FreeValue(ctx, mod);
        free(src);
        free(dir);
        return exports;
    }
    setProp(ctx, mod, "exports", exports); // consumes exports
    setProp(ctx, mod, "id", newString(ctx, asMain ? "." : canonical));
    setProp(ctx, mod, "filename", newString(ctx, canonical));
    setProp(ctx, mod, "loaded", jsBool(false));
    setProp(ctx, mod, "parent", jsNull());
    setProp(ctx, mod, "children", JS_NewArray(ctx));
    setProp(ctx, mod, "path", newString(ctx, dir));
    setProp(ctx, mod, "paths", JS_NewArray(ctx));
    if (asMain && jsIsUndefined(self.mainModule))
        self.mainModule = JS_DupValue(ctx, mod);
    // Cache before executing so a cycle sees the partial exports object.
    JS_SetPropertyStr(ctx, self.requireCache, canonical, JS_DupValue(ctx, mod));

    const(char)* prefix = "(function (exports, require, module, __filename, __dirname) {";
    const(char)* suffix = "\n})";
    size_t plen = strlen(prefix), slen = strlen(suffix);
    size_t codeLen = len - codeOff;
    char* wrapper = cast(char*) malloc(plen + codeLen + slen + 1);
    if (wrapper is null)
    {
        JS_FreeValue(ctx, mod);
        free(src);
        free(dir);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(wrapper, prefix, plen);
    memcpy(wrapper + plen, src + codeOff, codeLen);
    memcpy(wrapper + plen + codeLen, suffix, slen + 1);
    free(src);

    JSValue fn = JS_Eval(ctx, wrapper, plen + len + slen, canonical, JS_EVAL_TYPE_GLOBAL);
    free(wrapper);
    if (jsIsException(fn))
    {
        evict(self, canonical);
        JS_FreeValue(ctx, mod);
        free(dir);
        return fn;
    }

    JSValue dirVal = newString(ctx, dir);
    JSValue reqFn = JS_NewCFunctionData(ctx, &jsModuleRequire, 1, 0, 1, &dirVal);
    if (!jsIsException(reqFn))
    {
        if (!attachRequireSurface(ctx, reqFn, self))
        {
            JS_FreeValue(ctx, reqFn);
            JS_FreeValue(ctx, dirVal);
            JS_FreeValue(ctx, mod);
            return jsException();
        }
        JSValue resolveFn = JS_NewCFunctionData(ctx, &jsModuleResolve, 1, 0, 1, &dirVal);
        if (jsIsException(resolveFn) || JS_SetPropertyStr(ctx, reqFn, "resolve", resolveFn) < 0)
        {
            JS_FreeValue(ctx, dirVal);
            JS_FreeValue(ctx, mod);
            return jsException();
        }
    }
    JS_FreeValue(ctx, dirVal);

    JSValue[5] args;
    args[0] = JS_GetPropertyStr(ctx, mod, "exports");
    args[1] = reqFn;
    args[2] = JS_DupValue(ctx, mod);
    args[3] = newString(ctx, canonical);
    args[4] = newString(ctx, dir);

    if (jsIsException(reqFn))
    {
        for (int i = 0; i < 5; ++i)
            JS_FreeValue(ctx, args[i]);
        JS_FreeValue(ctx, fn);
        JS_FreeValue(ctx, mod);
        evict(self, canonical);
        free(dir);
        return reqFn;
    }

    JSValue callResult = JS_Call(ctx, fn, args[0], 5, &args[0]);
    bool threw = jsIsException(callResult);

    for (int i = 0; i < 5; ++i)
        JS_FreeValue(ctx, args[i]);
    JS_FreeValue(ctx, fn);
    free(dir);
    if (threw)
    {
        // A module that threw must not stay cached: a second require() would
        // otherwise return a half-built exports object instead of re-throwing.
        evict(self, canonical);
        JS_FreeValue(ctx, mod);
        return callResult;
    }
    JS_FreeValue(ctx, callResult);

    JSValue exportsOut = JS_GetPropertyStr(ctx, mod, "exports");
    setProp(ctx, mod, "loaded", jsBool(true));
    JS_FreeValue(ctx, mod);
    return exportsOut;
}

// require(spec) with an explicit base directory. Used by the global `require`
// and by ESM modules that import CommonJS.
JSValue cjsRequireFrom(Runtime* self, const(char)* dir, const(char)* spec) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    Resolved r = resolveSpec(self, spec, dir);
    if (r.err != 0)
    {
        if (r.err == 13)
            return throwModuleError(ctx, "ERR_ACCESS_DENIED",
                                    "module path escapes the project root", spec);
        return throwModuleError(ctx, "MODULE_NOT_FOUND",
                                "cannot find module", spec);
    }
    if (r.kind == ModuleKind.builtin)
        return builtinValue(ctx, r.builtinAlias);
    if (r.kind == ModuleKind.esm)
    {
        JSValue e = throwModuleError(ctx, "ERR_REQUIRE_ESM",
                                     "require() of an ES module is not supported", r.path);
        free(r.path);
        return e;
    }
    if (r.kind == ModuleKind.json)
    {
        // JSON modules are cached like CJS modules: identity is stable and
        // mutations persist, matching require() of JSON in Node.
        JSValue cached = JS_GetPropertyStr(ctx, self.requireCache, r.path);
        if (jsIsException(cached))
        {
            free(r.path);
            return cached;
        }
        if (!jsIsUndefined(cached))
        {
            free(r.path);
            return cached;
        }
        JS_FreeValue(ctx, cached);
        JSValue v = readJson(self, r.path);
        if (!jsIsException(v))
            JS_SetPropertyStr(ctx, self.requireCache, r.path, JS_DupValue(ctx, v));
        free(r.path);
        return v;
    }
    JSValue loaded = cjsLoad(self, r.path);
    free(r.path);
    return loaded;
}

private extern(C) JSValue jsModuleRequireImpl(JSContext* ctx, JSValueConst, int argc,
                                             JSValueConst* argv, int magic,
                                             JSValue* funcData) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    if (argc < 1 || !jsIsString(argv[0]))
        return throwTypeError(ctx, "require() expects a string");
    const(char)* spec = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[0], &spec, &len))
        return jsException();
    if (memchr(spec, 0, len) !is null)
    {
        JS_FreeCString(ctx, spec);
        return throwTypeError(ctx, "require() specifier must not contain null bytes");
    }
    char* copy = cast(char*) malloc(len + 1);
    if (copy is null)
    {
        JS_FreeCString(ctx, spec);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(copy, spec, len);
    copy[len] = 0;
    JS_FreeCString(ctx, spec);

    size_t dirLen = 0;
    const(char)* dir = JS_ToCStringLen2(ctx, &dirLen, funcData[0], false);
    if (dir is null)
    {
        free(copy);
        return jsException();
    }
    JSValue v = cjsRequireFrom(self, dir, copy);
    JS_FreeCString(ctx, dir);
    free(copy);
    return v;
}

// Function data is the module directory, so a call made later (exported,
// deferred, or from another module) still resolves relative to its own file.
private extern(C) JSValue jsModuleRequire(JSContext* ctx, JSValueConst thisVal,
                                          int argc, JSValueConst* argv, int magic,
                                          JSValue* funcData) nothrow @nogc
{
    try
        return jsModuleRequireImpl(ctx, thisVal, argc, argv, magic, funcData);
    catch (Throwable)
    {
        import core.stdc.stdlib : exit;
        import djs.runtime : writeLiteral;
        writeLiteral(2, "djs: internal error\n");
        exit(70);
    }
}

private extern(C) JSValue jsRequireFromImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    if (argc < 2 || !jsIsString(argv[0]) || !jsIsString(argv[1]))
        return throwTypeError(ctx, "requireFrom(dir, spec) expects strings");
    const(char)* dir = null;
    const(char)* spec = null;
    size_t dl = 0, sl = 0;
    if (!toStringView(ctx, argv[0], &dir, &dl) || !toStringView(ctx, argv[1], &spec, &sl))
        return jsException();
    if (memchr(dir, 0, dl) !is null || memchr(spec, 0, sl) !is null)
    {
        JS_FreeCString(ctx, dir);
        JS_FreeCString(ctx, spec);
        return throwTypeError(ctx, "paths must not contain null bytes");
    }
    char* dirz = cast(char*) malloc(dl + 1);
    char* specz = cast(char*) malloc(sl + 1);
    if (dirz is null || specz is null)
    {
        free(dirz);
        free(specz);
        JS_FreeCString(ctx, dir);
        JS_FreeCString(ctx, spec);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(dirz, dir, dl);
    dirz[dl] = 0;
    memcpy(specz, spec, sl);
    specz[sl] = 0;
    JS_FreeCString(ctx, dir);
    JS_FreeCString(ctx, spec);
    JSValue v = cjsRequireFrom(self, dirz, specz);
    free(dirz);
    free(specz);
    return v;
}

extern(C) JSValue jsRequireFrom(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRequireFromImpl(ctx, thisVal, argc, argv);
}

private JSValue cjsResolveFrom(Runtime* self, const(char)* dir,
                               const(char)* spec) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    Resolved r = resolveSpec(self, spec, dir, false);
    if (r.kind == ModuleKind.builtin)
        return newString(ctx, spec);
    if (r.kind == ModuleKind.missing || r.path is null)
    {
        if (r.path !is null)
            free(r.path);
        return throwModuleError(ctx, "MODULE_NOT_FOUND", "Cannot find module", spec);
    }
    JSValue v = newString(ctx, r.path);
    free(r.path);
    return v;
}

private extern(C) JSValue jsModuleResolveImpl(JSContext* ctx, JSValueConst, int argc,
                                              JSValueConst* argv, int magic,
                                              JSValue* funcData) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    if (argc < 1 || !jsIsString(argv[0]))
        return throwTypeError(ctx, "require.resolve() expects a string");
    const(char)* spec = null;
    size_t len = 0;
    if (!toStringView(ctx, argv[0], &spec, &len))
        return jsException();
    if (memchr(spec, 0, len) !is null)
    {
        JS_FreeCString(ctx, spec);
        return throwTypeError(ctx, "specifier must not contain null bytes");
    }
    char* copy = cast(char*) malloc(len + 1);
    if (copy is null)
    {
        JS_FreeCString(ctx, spec);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(copy, spec, len);
    copy[len] = 0;
    JS_FreeCString(ctx, spec);

    size_t dirLen = 0;
    const(char)* dir = JS_ToCStringLen2(ctx, &dirLen, funcData[0], false);
    if (dir is null)
    {
        free(copy);
        return jsException();
    }
    JSValue v = cjsResolveFrom(self, dir, copy);
    JS_FreeCString(ctx, dir);
    free(copy);
    return v;
}

private extern(C) JSValue jsModuleResolve(JSContext* ctx, JSValueConst thisVal,
                                          int argc, JSValueConst* argv, int magic,
                                          JSValue* funcData) nothrow @nogc
{
    try
        return jsModuleResolveImpl(ctx, thisVal, argc, argv, magic, funcData);
    catch (Throwable)
    {
        import core.stdc.stdlib : exit;
        import djs.runtime : writeLiteral;
        writeLiteral(2, "djs: internal error\n");
        exit(70);
    }
}

private extern(C) JSValue jsResolveFromImpl(JSContext* ctx, JSValueConst, int argc,
                                            JSValueConst* argv) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return throwInternalError(ctx, "no runtime");
    if (argc < 2 || !jsIsString(argv[0]) || !jsIsString(argv[1]))
        return throwTypeError(ctx, "resolveFrom(dir, spec) expects strings");
    const(char)* dir = null;
    const(char)* spec = null;
    size_t dl = 0, sl = 0;
    if (!toStringView(ctx, argv[0], &dir, &dl) || !toStringView(ctx, argv[1], &spec, &sl))
        return jsException();
    char* dirz = cast(char*) malloc(dl + 1);
    char* specz = cast(char*) malloc(sl + 1);
    if (dirz is null || specz is null)
    {
        free(dirz);
        free(specz);
        JS_FreeCString(ctx, dir);
        JS_FreeCString(ctx, spec);
        return throwInternalError(ctx, "out of memory");
    }
    memcpy(dirz, dir, dl);
    dirz[dl] = 0;
    memcpy(specz, spec, sl);
    specz[sl] = 0;
    JS_FreeCString(ctx, dir);
    JS_FreeCString(ctx, spec);
    JSValue v = cjsResolveFrom(self, dirz, specz);
    free(dirz);
    free(specz);
    return v;
}

extern(C) JSValue jsResolveFrom(JSContext* ctx, JSValueConst thisVal, int argc,
                                JSValueConst* argv) nothrow @nogc
{
    return guarded!jsResolveFromImpl(ctx, thisVal, argc, argv);
}

// Node puts the module registry, the entry module and the extension table on
// every require function (the global one and each module's own copy).
private bool attachRequireSurface(JSContext* ctx, JSValue req, Runtime* self) @nogc nothrow
{
    if (JS_SetPropertyStr(ctx, req, "cache", JS_DupValue(ctx, self.requireCache)) < 0)
        return false;
    JSValue main = jsIsUndefined(self.mainModule) ? jsUndefined() : JS_DupValue(ctx, self.mainModule);
    if (JS_SetPropertyStr(ctx, req, "main", main) < 0)
        return false;
    if (jsIsUndefined(self.requireExtensions))
    {
        JSValue ext = JS_NewObject(ctx);
        if (jsIsException(ext) || JS_SetPropertyStr(ctx, req, "extensions", ext) < 0)
            return false;
    }
    else if (JS_SetPropertyStr(ctx, req, "extensions", JS_DupValue(ctx, self.requireExtensions)) < 0)
        return false;
    return true;
}

private extern(C) JSValue jsRequireCacheImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || jsIsUndefined(self.requireCache))
        return JS_NewObject(ctx);
    return JS_DupValue(ctx, self.requireCache);
}

extern(C) JSValue jsRequireCache(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{
    return guarded!jsRequireCacheImpl(ctx, thisVal, argc, argv);
}

private extern(C) JSValue jsMainModuleImpl(JSContext* ctx, JSValueConst, int, JSValueConst*) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null || jsIsUndefined(self.mainModule))
        return jsUndefined();
    return JS_DupValue(ctx, self.mainModule);
}

extern(C) JSValue jsMainModule(JSContext* ctx, JSValueConst thisVal, int argc, JSValueConst* argv) nothrow @nogc
{
    return guarded!jsMainModuleImpl(ctx, thisVal, argc, argv);
}

bool installCjs(Runtime* self, JSValueConst djs) @nogc nothrow
{
    JSContext* ctx = self.ctx;
    if (!addNativeFunction(ctx, djs, "requireFrom", &jsRequireFrom, 2))
        return false;
    if (!addNativeFunction(ctx, djs, "resolveFrom", &jsResolveFrom, 2))
        return false;
    if (!addNativeFunction(ctx, djs, "requireCache", &jsRequireCache, 0))
        return false;
    if (!addNativeFunction(ctx, djs, "mainModule", &jsMainModule, 0))
        return false;
    JSValue global = JS_GetGlobalObject(ctx);
    if (jsIsException(global))
        return false;
    JSValue rootVal = newString(ctx, self.rootDir);
    JSValue req = JS_NewCFunctionData(ctx, &jsModuleRequire, 1, 0, 1, &rootVal);
    JS_FreeValue(ctx, rootVal);
    if (jsIsException(req))
    {
        JS_FreeValue(ctx, global);
        return false;
    }
    JSValue resolveFn = JS_NewCFunctionData(ctx, &jsModuleResolve, 1, 0, 1, &rootVal);
    if (jsIsException(resolveFn))
    {
        JS_FreeValue(ctx, req);
        JS_FreeValue(ctx, global);
        return false;
    }
    if (JS_SetPropertyStr(ctx, req, "resolve", resolveFn) < 0)
    {
        JS_FreeValue(ctx, req);
        JS_FreeValue(ctx, global);
        return false;
    }
    if (!attachRequireSurface(ctx, req, self))
    {
        JS_FreeValue(ctx, req);
        JS_FreeValue(ctx, global);
        return false;
    }
    bool ok = JS_SetPropertyStr(ctx, global, "require", req) > 0;
    JS_FreeValue(ctx, global);
    return ok;
}
