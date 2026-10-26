module djs.modules.esm;

import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy, strcmp, strlen;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.modules.cjs : cjsLoad, installCjs;
import djs.modules.cjsnames : NameSet, SpecSet, collectCjsExportData, nameSetFree,
    specSetFree;
import djs.modules.classify : ModuleKind, builtinAlias, classifyPath;
import djs.modules.path : dirNameAlloc, hasSuffix, isAbsolutePath, pathJoin,
    neutraliseShebang, readFileAlloc, realPathAlloc, xstrdup;
import djs.modules.resolve : Resolved, resolveSpec;
import djs.runtime : Runtime, runtimeOf, runtimeRunScriptFlags, writeLiteral;

// Small malloc-backed builder; the module sources are assembled here rather
// than by concatenating GC strings.
private bool isIdentStart(char c) @nogc nothrow
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$';
}

private bool isIdentPart(char c) @nogc nothrow
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

private struct Buf
{
    char* p;
    size_t len;
    size_t cap;
    bool failed;

    void reserve(size_t extra) @nogc nothrow
    {
        if (failed)
            return;
        if (len + extra + 1 <= cap)
            return;
        size_t next = cap == 0 ? 256 : cap;
        while (next < len + extra + 1)
            next *= 2;
        char* grown = cast(char*) realloc(p, next);
        if (grown is null)
        {
            failed = true;
            return;
        }
        p = grown;
        cap = next;
    }

    void add(const(char)* s) @nogc nothrow
    {
        size_t n = strlen(s);
        reserve(n);
        if (failed)
            return;
        memcpy(p + len, s, n);
        len += n;
        p[len] = 0;
    }

    void addChar(char c) @nogc nothrow
    {
        reserve(1);
        if (failed)
            return;
        p[len++] = c;
        p[len] = 0;
    }

    // Escape a path/specifier for use inside a double-quoted JS string.
    void addEscaped(const(char)* s) @nogc nothrow
    {
        for (size_t i = 0; s[i] != 0; ++i)
        {
            char c = s[i];
            if (c == '"' || c == '\\')
            {
                addChar('\\');
                addChar(c);
            }
            else if (c == '\n')
            {
                add("\\n");
            }
            else
            {
                addChar(c);
            }
        }
    }

    // Escape the payload as a complete JS string literal; the parser then sees
    // data, never code, and JSON.parse preserves "__proto__" as an own key.
    void addJsString(const(char)* s) @nogc nothrow
    {
        addChar('"');
        for (size_t i = 0; s[i] != 0; ++i)
        {
            const ubyte c = cast(ubyte) s[i];
            if (c == '"' || c == '\\')
            {
                addChar('\\');
                addChar(cast(char) c);
            }
            else if (c < 0x20)
            {
                static immutable hex = "0123456789abcdef";
                addChar('\\');
                addChar('u');
                addChar('0');
                addChar('0');
                addChar(hex[c >> 4]);
                addChar(hex[c & 0x0f]);
            }
            else
            {
                addChar(cast(char) c);
            }
        }
        addChar('"');
    }

    char* finish() @nogc nothrow
    {
        if (failed)
        {
            free(p);
            return null;
        }
        if (p is null)
        {
            p = cast(char*) malloc(1);
            if (p is null)
                return null;
            p[0] = 0;
        }
        return p;
    }
}

private bool isBuiltinAlias(const(char)* name) @nogc nothrow
{
    return name !is null && name[0] == 'd' && name[1] == 'j' && name[2] == 's' &&
        name[3] == ':';
}

private void addExport(Buf* b, const(char)* name) @nogc nothrow
{
    b.add("export const ");
    b.add(name);
    b.add(" = __m.");
    b.add(name);
    b.add(";\n");
}

// ESM named exports mirror the CommonJS surface: every enumerable key of the
// module object is re-exported, so `import { createServer } from 'node:http'`
// works wherever `require('node:http').createServer` does. Keep these lists in
// step with the prelude; tests/js/esm_builtin_parity.js fails when one falls
// behind.
private static immutable string[] fsExports = ["Dir", "Dirent", "FSWatcher", "ReadStream", "Stats", "WriteStream", "access", "accessSync", "appendFile", "appendFileSync", "chmod", "chmodSync", "chown", "chownSync", "close", "closeSync", "constants", "copyFile", "copyFileSync", "cp", "cpSync", "createReadStream", "createWriteStream", "existsSync", "fchmod", "fchmodSync", "fchown", "fchownSync", "fdatasync", "fdatasyncSync", "fstat", "fstatSync", "fsync", "fsyncSync", "ftruncate", "ftruncateSync", "glob", "globSync", "link", "linkSync", "lstat", "lstatSync", "mkdir", "mkdirSync", "mkdtemp", "mkdtempSync", "open", "openAsBlob", "openSync", "opendir", "opendirSync", "promises", "read", "readFile", "readFileSync", "readSync", "readdir", "readdirSync", "readlink", "readlinkSync", "readv", "readvSync", "realpath", "realpathSync", "rename", "renameSync", "rm", "rmSync", "stat", "statSync", "statfs", "statfsSync", "symlink", "symlinkSync", "truncate", "truncateSync", "unlink", "unlinkSync", "unwatchFile", "watch", "watchFile", "write", "writeFile", "writeFileSync", "writeSync", "writev", "writevSync"];
private static immutable string[] fs_promisesExports = ["access", "appendFile", "chmod", "chown", "copyFile", "cp", "glob", "link", "lstat", "mkdir", "mkdtemp", "open", "opendir", "readFile", "readdir", "readlink", "readv", "realpath", "rename", "rm", "stat", "statfs", "symlink", "truncate", "unlink", "writeFile", "writev"];
private static immutable string[] pathExports = ["basename", "delimiter", "dirname", "extname", "format", "isAbsolute", "join", "normalize", "parse", "posix", "relative", "resolve", "sep", "toNamespacedPath", "win32"];
private static immutable string[] path_win32Exports = ["basename", "delimiter", "dirname", "extname", "format", "isAbsolute", "join", "normalize", "parse", "resolve", "sep", "toNamespacedPath", "win32"];
private static immutable string[] path_posixExports = ["basename", "delimiter", "dirname", "extname", "format", "isAbsolute", "join", "normalize", "parse", "posix", "relative", "resolve", "sep", "toNamespacedPath", "win32"];
private static immutable string[] osExports = ["EOL", "arch", "availableParallelism", "constants", "cpus", "devNull", "endianness", "eol", "freemem", "homedir", "hostname", "loadavg", "machine", "networkInterfaces", "platform", "release", "tmpdir", "totalmem", "type", "uptime", "userInfo"];
private static immutable string[] eventsExports = ["EventEmitter", "addAbortListener", "captureRejections", "defaultMaxListeners", "errorMonitor", "getEventListeners", "on", "once", "setMaxListeners"];
private static immutable string[] streamExports = ["Duplex", "PassThrough", "Readable", "Stream", "Transform", "Writable", "addAbortSignal", "finished", "getDefaultHighWaterMark", "pipeline", "setDefaultHighWaterMark"];
private static immutable string[] stream_consumersExports = ["arrayBuffer", "blob", "buffer", "json", "text"];
private static immutable string[] stream_promisesExports = ["finished", "pipeline"];
private static immutable string[] stream_webExports = ["ReadableStream", "TransformStream", "WritableStream"];
private static immutable string[] urlExports = ["URL", "URLSearchParams", "fileURLToPath", "format", "parse", "pathToFileURL", "resolve", "urlToHttpOptions"];
private static immutable string[] utilExports = ["aborted", "callbackify", "debuglog", "deprecate", "format", "formatWithOptions", "getSystemErrorName", "inherits", "inspect", "isDeepStrictEqual", "parseArgs", "promisify", "stripVTControlCharacters", "styleText", "types"];
private static immutable string[] timersExports = ["clearImmediate", "clearInterval", "clearTimeout", "setImmediate", "setInterval", "setTimeout"];
private static immutable string[] timers_promisesExports = ["scheduler", "setImmediate", "setTimeout"];
private static immutable string[] bufferExports = ["Buffer", "constants"];
private static immutable string[] netExports = ["Server", "Socket", "connect", "createConnection", "createServer", "isIP", "isIPv4", "isIPv6"];
private static immutable string[] dnsExports = ["getServers", "lookup", "lookupService", "promises", "resolve", "resolveAny", "resolve4", "resolve6", "resolveCname", "resolveMx", "resolveNs", "resolvePtr", "resolveSoa", "resolveSrv", "resolveTxt", "reverse", "setServers"];
private static immutable string[] dns_promisesExports = ["lookup", "lookupService", "resolve", "resolveAny", "resolve4", "resolve6", "resolveCname", "resolveMx", "resolveNs", "resolvePtr", "resolveSoa", "resolveSrv", "resolveTxt", "reverse"];
private static immutable string[] httpExports = ["Agent", "ClientRequest", "IncomingMessage", "METHODS", "STATUS_CODES", "Server", "ServerResponse", "createServer", "get", "globalAgent", "maxHeaderSize", "request", "validateHeaderName", "validateHeaderValue"];
private static immutable string[] httpsExports = ["Agent", "METHODS", "STATUS_CODES", "Server", "createServer", "get", "globalAgent", "request"];
private static immutable string[] tlsExports = ["Server", "TLSSocket", "connect", "createServer"];
private static immutable string[] async_hooksExports = ["AsyncLocalStorage", "AsyncResource", "createHook", "executionAsyncId", "executionAsyncResource", "triggerAsyncId"];
private static immutable string[] util_typesExports = ["isAnyArrayBuffer", "isArrayBuffer", "isArrayBufferView", "isBigInt64Array", "isBigUint64Array", "isBoxedPrimitive", "isDataView", "isDate", "isFloat32Array", "isFloat64Array", "isInt16Array", "isInt32Array", "isInt8Array", "isKeyObject", "isMap", "isNativeError", "isPromise", "isProxy", "isRegExp", "isSet", "isTypedArray", "isUint16Array", "isUint32Array", "isUint8Array", "isUint8ClampedArray"];
private static immutable string[] consoleExports = ["Console", "assert", "clear", "count", "countReset", "debug", "dir", "dirxml", "error", "group", "groupCollapsed", "groupEnd", "info", "log", "profile", "profileEnd", "table", "time", "timeEnd", "timeLog", "timeStamp", "trace", "warn"];
private static immutable string[] sqliteExports = ["DatabaseSync", "StatementSync"];

private static immutable string[] child_processExports = ["ChildProcess", "exec", "execFile", "execFileSync", "execSync", "fork", "spawn", "spawnSync"];
private static immutable string[] cryptoExports = ["KeyObject", "X509Certificate", "createCipheriv", "createDecipheriv", "createHash", "createHmac", "createPrivateKey", "createPublicKey", "createSecretKey", "createSign", "createVerify", "generateKeyPair", "generateKeyPairSync", "getRandomValues", "hkdf", "hkdfSync", "pbkdf2", "pbkdf2Sync", "randomBytes", "randomFill", "randomFillSync", "randomUUID", "scrypt", "scryptSync", "sign", "subtle", "timingSafeEqual", "verify", "webcrypto"];
private static immutable string[] zlibExports = ["brotliCompressSync", "brotliDecompressSync", "constants", "crc32", "createDeflate", "createDeflateRaw", "createGunzip", "createGzip", "createInflate", "createInflateRaw", "deflateRawSync", "deflateSync", "gunzipSync", "gzipSync", "inflateRawSync", "inflateSync"];
private static immutable string[] dgramExports = ["createSocket"];
private static immutable string[] readlineExports = ["clearLine", "clearScreenDown", "createInterface", "cursorTo", "moveCursor"];
private static immutable string[] readline_promisesExports = ["createInterface"];
private static immutable string[] worker_threadsExports = ["MessageChannel", "MessagePort", "Worker", "isMainThread", "parentPort", "threadId", "workerData", "markAsUncloneable", "markAsUntransferable"];
private static immutable string[] ttyExports = ["isTTY", "isatty"];
private static immutable string[] querystringExports = ["escape", "parse", "stringify", "unescape"];
private static immutable string[] string_decoderExports = ["StringDecoder"];
private static immutable string[] perf_hooksExports = ["PerformanceObserver", "performance"];
private static immutable string[] diagnostics_channelExports = ["Channel", "channel", "hasSubscribers", "subscribe", "unsubscribe"];
private static immutable string[] trace_eventsExports = ["createTracing", "getEnabledCategories"];
private static immutable string[] clusterExports = ["_events", "_maxListeners", "disconnect", "fork", "isMaster", "isPrimary", "isWorker", "settings", "workers"];
private static immutable string[] vmExports = ["Script", "createContext", "isContext", "runInContext", "runInNewContext", "runInThisContext"];
private static immutable string[] v8Exports = ["cachedDataVersionTag", "deserialize", "getHeapCodeStatistics", "getHeapSpaceStatistics", "getHeapSnapshot", "getHeapStatistics", "serialize", "setFlagsFromString", "startupSnapshot", "writeHeapSnapshot"];
private static immutable string[] http2Exports = ["Http2Session", "connect", "constants", "createSecureServer", "createServer"];
private static immutable string[] assertExports = ["AssertionError", "deepEqual", "deepStrictEqual", "doesNotMatch", "doesNotReject", "doesNotThrow", "equal", "fail", "ifError", "match", "notDeepEqual", "notDeepStrictEqual", "notEqual", "notStrictEqual", "ok", "rejects", "strict", "strictEqual", "throws"];
private static immutable string[] assert_strictExports = ["AssertionError", "deepEqual", "deepStrictEqual", "doesNotMatch", "doesNotReject", "doesNotThrow", "equal", "fail", "ifError", "match", "notDeepEqual", "notDeepStrictEqual", "notEqual", "notStrictEqual", "ok", "rejects", "strict", "strictEqual", "throws"];
private static immutable string[] moduleExports = ["Module", "builtinModules", "createRequire", "isBuiltin", "syncBuiltinESMExports"];
private static immutable string[] processExports = ["arch", "argv", "argv0", "cpuUsage", "cwd", "chdir", "emitWarning", "env", "execArgv", "execPath", "exit", "exitCode", "features", "hrtime", "kill", "listenerCount", "listeners", "memoryUsage", "nextTick", "off", "on", "once", "permission", "pid", "platform", "ppid", "release", "removeAllListeners", "removeListener", "stderr", "stdin", "stdout", "title", "umask", "uptime", "version", "versions"];

// One row per builtin: specifier, export names, and the JS object the facade
// binds. Both the export list and the module source read this table, so a new
// builtin is one line and the two views cannot drift apart.
private struct BuiltinFacade
{
    string spec;
    const(string)[] exports;
    string binding;
}

private static immutable string[] noExports = [];

private static immutable BuiltinFacade[] builtinFacades = [
    BuiltinFacade("djs:fs", fsExports, "globalThis.fs"),
    BuiltinFacade("djs:fs/promises", fs_promisesExports, "globalThis.fs.promises"),
    BuiltinFacade("djs:path", pathExports, "globalThis.path"),
    BuiltinFacade("djs:path_win32", path_win32Exports, "globalThis.path.win32"),
    BuiltinFacade("djs:path_posix", path_posixExports, "globalThis.path.posix"),
    BuiltinFacade("djs:os", osExports, "globalThis.os"),
    BuiltinFacade("djs:events", eventsExports, "globalThis.events"),
    BuiltinFacade("djs:stream", streamExports, "globalThis.stream"),
    BuiltinFacade("djs:stream_consumers", stream_consumersExports, "globalThis.streamConsumers"),
    BuiltinFacade("djs:stream_promises", stream_promisesExports, "globalThis.stream_promises"),
    BuiltinFacade("djs:stream_web", stream_webExports, "globalThis.stream_web"),
    BuiltinFacade("djs:url", urlExports, "globalThis.url"),
    BuiltinFacade("djs:util", utilExports, "globalThis.util"),
    BuiltinFacade("djs:util/types", util_typesExports, "globalThis.util.types"),
    BuiltinFacade("djs:async_hooks", async_hooksExports, "globalThis.async_hooks"),
    BuiltinFacade("djs:sqlite", sqliteExports, "globalThis.sqlite"),
    BuiltinFacade("djs:console", consoleExports, "globalThis.console"),
    BuiltinFacade("djs:timers", timersExports, "globalThis.timers"),
    BuiltinFacade("djs:timers/promises", timers_promisesExports, "globalThis.timersPromises"),
    BuiltinFacade("djs:buffer", bufferExports, "globalThis.buffer"),
    BuiltinFacade("djs:net", netExports, "globalThis.net"),
    BuiltinFacade("djs:dns", dnsExports, "globalThis.dns"),
    BuiltinFacade("djs:dns_promises", dns_promisesExports, "globalThis.dns_promises"),
    BuiltinFacade("djs:http", httpExports, "globalThis.http"),
    BuiltinFacade("djs:https", httpsExports, "globalThis.https"),
    BuiltinFacade("djs:tls", tlsExports, "globalThis.tls"),
    BuiltinFacade("djs:child_process", child_processExports, "globalThis.child_process"),
    BuiltinFacade("djs:crypto", cryptoExports, "globalThis.crypto"),
    BuiltinFacade("djs:zlib", zlibExports, "globalThis.zlib"),
    BuiltinFacade("djs:dgram", dgramExports, "globalThis.dgram"),
    BuiltinFacade("djs:readline", readlineExports, "globalThis.readline"),
    BuiltinFacade("djs:readline_promises", readline_promisesExports, "globalThis.readlinePromises"),
    BuiltinFacade("djs:worker_threads", worker_threadsExports, "globalThis.worker_threads"),
    BuiltinFacade("djs:tty", ttyExports, "globalThis.tty"),
    BuiltinFacade("djs:querystring", querystringExports, "globalThis.querystring"),
    BuiltinFacade("djs:string_decoder", string_decoderExports, "globalThis.string_decoder"),
    BuiltinFacade("djs:perf_hooks", perf_hooksExports, "globalThis.perf_hooks"),
    BuiltinFacade("djs:diagnostics_channel", diagnostics_channelExports, "globalThis.diagnostics_channel"),
    BuiltinFacade("djs:trace_events", trace_eventsExports, "globalThis.trace_events"),
    BuiltinFacade("djs:cluster", clusterExports, "globalThis.cluster"),
    BuiltinFacade("djs:vm", vmExports, "globalThis.vm"),
    BuiltinFacade("djs:v8", v8Exports, "globalThis.v8"),
    BuiltinFacade("djs:http2", http2Exports, "globalThis.http2"),
    BuiltinFacade("djs:assert", assertExports, "globalThis.assert"),
    BuiltinFacade("djs:assert_strict", assert_strictExports, "globalThis.assert_strict"),
    BuiltinFacade("djs:module", moduleExports, "globalThis.nodeModule"),
    BuiltinFacade("djs:process", processExports, "globalThis.process"),
    BuiltinFacade("djs:ws", noExports, "globalThis.ws"),
];

private bool uniqueBuiltinSpecs() @safe
{
    foreach (i, a; builtinFacades)
        foreach (j, b; builtinFacades)
            if (i < j && a.spec == b.spec)
                return false;
    return true;
}

static assert(uniqueBuiltinSpecs(), "duplicate builtin specifier");

private const(BuiltinFacade)* builtinFacade(const(char)[] spec) pure @safe @nogc nothrow
{
    foreach (i; 0 .. builtinFacades.length)
        if (builtinFacades[i].spec == spec)
            return &builtinFacades[i];
    return null;
}

@safe unittest
{
    assert(builtinFacade("djs:fs").binding == "globalThis.fs");
    assert(builtinFacade("djs:fs/promises").binding == "globalThis.fs.promises");
    assert(builtinFacade("djs:ws") !is null);
    assert(builtinFacade("djs:ws").exports.length == 0);
    assert(builtinFacade("not:a:builtin") is null);
    foreach (ref f; builtinFacades)
    {
        assert(f.spec.length > 0);
        assert(f.binding.length > 0);
        assert(f.spec[0 .. 4] == "djs:");
    }
}

// Build a one-line ESM facade over a prelude/native object.
private char* builtinModuleSource(const(char)* builtin) @nogc nothrow
{
    if (builtin is null)
        return null;
    const(BuiltinFacade)* facade = builtinFacade(builtin[0 .. strlen(builtin)]);
    Buf b;
    b.add("const __m = ");
    b.add(facade is null ? "globalThis.process" : facade.binding.ptr);
    b.add(";\nexport default __m;\n");
    if (facade !is null)
        foreach (name; facade.exports)
            addExport(&b, name.ptr);
    return b.finish();
}

private enum int maxCjsReexportDepth = 32;

// TypeScript and Node CJS barrels re-export with helpers such as
// `__exportStar(require("./types"), exports)`. The named exports only exist
// in the required module at runtime, so scan that module too (and its own
// re-exports), bounded by depth and the current ancestry to tolerate cycles.
private void collectCjsNames(Runtime* self, const(char)* path,
                             const(char)* src, size_t len,
                             NameSet* names,
                             const(char)*[maxCjsReexportDepth] visited,
                             size_t visitedCount, int depth) @nogc nothrow
{
    if (self is null || path is null || src is null || names is null)
        return;
    if (depth >= maxCjsReexportDepth || visitedCount >= visited.length)
        return;
    foreach (i; 0 .. visitedCount)
        if (visited[i] !is null && strcmp(visited[i], path) == 0)
            return;
    visited[visitedCount] = path;

    SpecSet specs;
    collectCjsExportData(src, len, names, &specs);
    if (specs.count == 0)
    {
        specSetFree(&specs);
        return;
    }

    char* dir = dirNameAlloc(path);
    if (dir is null)
    {
        specSetFree(&specs);
        return;
    }
    foreach (i; 0 .. specs.count)
    {
        Resolved r = resolveSpec(self, specs.specs[i], dir, false);
        if (r.err == 0 && r.kind == ModuleKind.cjs && r.path !is null)
        {
            char* sub = null;
            size_t subLen = 0;
            int err = 0;
            if (readFileAlloc(r.path, &sub, &subLen, &err))
            {
                neutraliseShebang(sub, subLen);
                collectCjsNames(self, r.path, sub, subLen, names, visited,
                                visitedCount + 1, depth + 1);
                free(sub);
            }
        }
        if (r.path !is null)
            free(r.path);
    }
    free(dir);
    specSetFree(&specs);
}

private char* cjsModuleSource(Runtime* self, const(char)* path,
                              const(char)* src, size_t len) @nogc nothrow
{
    char* dir = dirNameAlloc(path);
    if (dir is null)
        return null;
    Buf b;
    b.add("const __m = globalThis.__djs.requireFrom(\"");
    b.addEscaped(dir);
    b.add("\", \"");
    b.addEscaped(path);
    b.add("\");\nexport default __m;\n");
    NameSet names;
    const(char)*[maxCjsReexportDepth] visited = void;
    collectCjsNames(self, path, src, len, &names, visited, 0, 0);
    size_t anon = 0;
    for (size_t i = 0; i < names.count; ++i)
    {
        const(char)* name = names.names[i];
        size_t nl = strlen(name);
        // `export const NAME` needs a valid identifier; a string-key export
        // (exports['quoted-key'] = ...) is exposed through a string export
        // name instead, which is still reachable via the namespace object.
        bool ident = nl > 0 && isIdentStart(name[0]);
        for (size_t k = 1; ident && k < nl; ++k)
            if (!isIdentPart(name[k]))
                ident = false;
        if (ident)
        {
            b.add("export const ");
            b.add(name);
            b.add(" = __m.");
            b.add(name);
            b.add(";\n");
        }
        else
        {
            char[24] idxBuf = void;
            size_t o = 0;
            ulong v = anon++;
            do { idxBuf[o++] = cast(char) ('0' + v % 10); v /= 10; } while (v > 0);
            b.add("const __x");
            for (size_t d = o; d > 0; --d) b.addChar(idxBuf[d - 1]);
            b.add(" = __m[");
            b.addJsString(name);
            b.add("];\nexport { __x");
            for (size_t d = o; d > 0; --d) b.addChar(idxBuf[d - 1]);
            b.add(" as ");
            b.addJsString(name);
            b.add(" };\n");
        }
    }
    nameSetFree(&names);
    free(dir);
    return b.finish();
}

private char* jsonModuleSource(const(char)* src) @nogc nothrow
{
    Buf b;
    b.add("export default JSON.parse(");
    b.addJsString(src);
    b.add(");\n");
    return b.finish();
}

private JSValue throwModuleError(JSContext* ctx, const(char)* code,
                                 const(char)* message, const(char)* path) @nogc nothrow
{
    // Node names the specifier: `Cannot find module 'x' imported from y`.
    // Without it the error is a dead end for anyone debugging a package.
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
    JSValue e = makeError(ctx, enriched !is null ? enriched : message, code, path, "import");
    free(enriched);
    if (jsIsException(e))
        return e;
    return throwError(ctx, e);
}

private extern(C) char* esmNormalizeImpl(JSContext* ctx, const(char)* base,
                                         const(char)* name, JSValueConst,
                                         void* opaque) nothrow @nogc
{
    Runtime* self = cast(Runtime*) opaque;
    if (self is null || name is null)
        return null;
    const(char)* builtin = builtinAlias(name);
    if (builtin !is null)
    {
        char* normalized = cast(char*) js_malloc(ctx, strlen(builtin) + 1);
        if (normalized is null)
            return null;
        memcpy(normalized, builtin, strlen(builtin) + 1);
        return normalized;
    }
    char* baseDir = null;
    if (base !is null && !isBuiltinAlias(base))
    {
        // `base` is the importing module's canonical path; the entry pass uses
        // the root directory.
        baseDir = dirNameAlloc(base);
    }
    else
    {
        baseDir = xstrdup(self.rootDir);
    }
    if (baseDir is null)
    {
        throwInternalError(ctx, "out of memory");
        return null;
    }
    Resolved r = resolveSpec(self, name, baseDir, true);
    free(baseDir);
    if (r.err != 0)
    {
        if (r.err == 13)
            throwModuleError(ctx, "ERR_ACCESS_DENIED",
                             "module path escapes the project root", name);
        else
            throwModuleError(ctx, "ERR_MODULE_NOT_FOUND", "cannot find module", name);
        return null;
    }
    char* path = r.path;
    size_t n = strlen(path);
    char* normalized = cast(char*) js_malloc(ctx, n + 1);
    if (normalized !is null)
        memcpy(normalized, path, n + 1);
    free(path);
    if (normalized is null)
        throwInternalError(ctx, "out of memory");
    return normalized;
}

private extern(C) char* esmNormalize4(JSContext* ctx, const(char)* base,
                                      const(char)* name, void* opaque) nothrow @nogc
{
    try
        return esmNormalizeImpl(ctx, base, name, jsUndefined(), opaque);
    catch (Throwable)
    {
        import core.stdc.stdlib : exit;
        import djs.runtime : writeLiteral;
        writeLiteral(2, "djs: internal error\n");
        exit(70);
    }
}

private extern(C) char* esmNormalize(JSContext* ctx, const(char)* base,
                                     const(char)* name, JSValueConst attrs,
                                     void* opaque) nothrow @nogc
{
    try
        return esmNormalizeImpl(ctx, base, name, attrs, opaque);
    catch (Throwable)
    {
        import core.stdc.stdlib : exit;
        import djs.runtime : writeLiteral;
        writeLiteral(2, "djs: internal error\n");
        exit(70);
    }
}

private extern(C) int esmCheckAttrsImpl(JSContext* ctx, void*, JSValueConst attrs) nothrow @nogc
{
    if (jsIsUndefined(attrs) || jsIsNull(attrs))
        return 0;
    JSValue type = JS_GetPropertyStr(ctx, attrs, "type");
    if (jsIsException(type))
        return -1;
    if (jsIsUndefined(type) || jsIsNull(type))
    {
        JS_FreeValue(ctx, type);
        return 0;
    }
    size_t len = 0;
    const(char)* s = JS_ToCStringLen2(ctx, &len, type, false);
    bool json = s !is null && len == 4 && s[0] == 'j' && s[1] == 's' &&
        s[2] == 'o' && s[3] == 'n';
    if (s !is null)
        JS_FreeCString(ctx, s);
    JS_FreeValue(ctx, type);
    if (json)
        return 0;
    throwTypeError(ctx, "unsupported import attribute (only type: \"json\")");
    return -1;
}

private extern(C) int esmCheckAttrs(JSContext* ctx, void* opaque, JSValueConst attrs) nothrow @nogc
{
    try
        return esmCheckAttrsImpl(ctx, opaque, attrs);
    catch (Throwable)
    {
        import core.stdc.stdlib : exit;
        import djs.runtime : writeLiteral;
        writeLiteral(2, "djs: internal error\n");
        exit(70);
    }
}

private JSModuleDef* evalModule(JSContext* ctx, char* source, size_t len,
                                const(char)* name) @nogc nothrow
{
    JSValue v = JS_Eval(ctx, source, len, name,
                        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (jsIsException(v))
        return null;
    JSModuleDef* m = cast(JSModuleDef*) v.u.ptr;
    JS_FreeValue(ctx, v);
    return m;
}

private void setImportMeta(JSContext* ctx, JSModuleDef* m, const(char)* path) @nogc nothrow
{
    JSValue meta = JS_GetImportMeta(ctx, m);
    if (jsIsException(meta))
        return;
    char* dir = dirNameAlloc(path);
    size_t plen = strlen(path);
    // file URLs percent-encode everything outside the unreserved set; without
    // this a space or '#' in a path produces a URL that cannot be re-parsed.
    char* url = cast(char*) malloc(plen * 3 + 8);
    if (url !is null)
    {
        static const(char)* hex = "0123456789ABCDEF";
        size_t o = 0;
        memcpy(url, "file://".ptr, 7);
        o = 7;
        for (size_t i = 0; i < plen; ++i)
        {
            ubyte c = cast(ubyte) path[i];
            bool keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                        c == '_' || c == '~' || c == '/' || c == ':';
            if (keep)
                url[o++] = cast(char) c;
            else
            {
                url[o++] = '%';
                url[o++] = hex[c >> 4];
                url[o++] = hex[c & 0x0F];
            }
        }
        url[o] = 0;
        setProp(ctx, meta, "url", newString(ctx, url));
        free(url);
    }
    setProp(ctx, meta, "filename", newString(ctx, path));
    if (dir !is null)
    {
        setProp(ctx, meta, "dirname", newString(ctx, dir));
        free(dir);
    }
    JS_FreeValue(ctx, meta);
}

private extern(C) JSModuleDef* esmLoadImpl(JSContext* ctx, const(char)* name,
                                           void*, JSValueConst attrs) nothrow @nogc
{
    Runtime* self = runtimeOf(ctx);
    if (self is null)
        return null;

    if (isBuiltinAlias(name))
    {
        char* src = builtinModuleSource(name);
        if (src is null)
        {
            throwInternalError(ctx, "out of memory");
            return null;
        }
        JSModuleDef* m = evalModule(ctx, src, strlen(src), name);
        free(src);
        return m;
    }

    ModuleKind kind = classifyPath(name, self.rootDir);
    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(name, &src, &len, &err))
    {
        throwModuleError(ctx, "ERR_MODULE_NOT_FOUND", "cannot read module", name);
        return null;
    }
    neutraliseShebang(src, len);

    char* moduleSource = null;
    size_t moduleLen = 0;
    if (kind == ModuleKind.json)
    {
        moduleSource = jsonModuleSource(src);
        free(src);
        src = null;
    }
    else if (kind == ModuleKind.cjs)
    {
        moduleSource = cjsModuleSource(self, name, src, len);
        free(src);
        src = null;
    }
    else
    {
        moduleSource = src;
        moduleLen = len;
        src = null;
    }
    if (moduleSource is null)
    {
        free(src);
        throwInternalError(ctx, "out of memory");
        return null;
    }
    if (moduleLen == 0)
        moduleLen = strlen(moduleSource);

    JSModuleDef* m = evalModule(ctx, moduleSource, moduleLen, name);
    free(moduleSource);
    if (m is null)
        return null;
    setImportMeta(ctx, m, name);
    cast(void) attrs;
    return m;
}

private extern(C) JSModuleDef* esmLoad(JSContext* ctx, const(char)* name,
                                       void* opaque, JSValueConst attrs) nothrow @nogc
{
    try
        return esmLoadImpl(ctx, name, opaque, attrs);
    catch (Throwable)
    {
        import core.stdc.stdlib : exit;
        import djs.runtime : writeLiteral;
        writeLiteral(2, "djs: internal error\n");
        exit(70);
    }
}

bool installModules(Runtime* self, JSValueConst djs) @nogc nothrow
{
    if (!installCjs(self, djs))
        return false;
    JS_SetModuleLoaderFunc2(self.rt, &esmNormalize4, &esmLoad, &esmCheckAttrs, self);
    // The loader slot takes the four-argument normalizer; the attributes-aware
    // five-argument entry point is installed separately.
    JS_SetModuleNormalizeFunc2(self.rt, &esmNormalize);
    return true;
}

// Compile an entry module, populate import.meta, then evaluate it. Module
// evaluation can be asynchronous (top-level await), so the caller drains jobs
// and runs the loop afterwards.
private bool runModuleSource(Runtime* self, char* src, size_t len,
                             const(char)* path) @nogc nothrow
{
    import djs.runtime : runtimeDrainJobs, runtimePrintException, runtimeRunLoop;
    JSContext* ctx = self.ctx;
    JSValue v = JS_Eval(ctx, src, len, path,
                        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (jsIsException(v))
    {
        runtimePrintException(self, ctx);
        self.failed = true;
        self.exitCode = 1;
        return false;
    }
    JSModuleDef* m = cast(JSModuleDef*) v.u.ptr;
    setImportMeta(ctx, m, path);
    JSValue r = JS_EvalFunction(ctx, v);
    if (jsIsException(r))
    {
        runtimePrintException(self, ctx);
        self.failed = true;
        self.exitCode = 1;
        return false;
    }
    JS_FreeValue(ctx, r);
    if (runtimeDrainJobs(self) < 0)
        return false;
    runtimeRunLoop(self);
    return !self.failed;
}

// Entry dispatch. `asScript` distinguishes a .js script (global eval, require
// available) from a .cjs module (wrapper + module object).
bool runEntry(Runtime* self, const(char)* path, ModuleKind kind, bool asScript) @nogc nothrow
{
    if (kind == ModuleKind.esm)
    {
        char* src = null;
        size_t len = 0;
        int err = 0;
        if (!readFileAlloc(path, &src, &len, &err))
        {
            writeLiteral(2, "djs: cannot read entry module\n");
            self.failed = true;
            self.exitCode = 1;
            return false;
        }
        neutraliseShebang(src, len);
        bool ok = runModuleSource(self, src, len, path);
        free(src);
        return ok;
    }
    if (kind == ModuleKind.cjs && !asScript)
    {
        JSValue v = cjsLoad(self, path, true);
        bool ok = !jsIsException(v);
        if (!ok)
        {
            import djs.runtime : runtimePrintException;
            runtimePrintException(self, self.ctx);
            self.failed = true;
            self.exitCode = 1;
            return false;
        }
        JS_FreeValue(self.ctx, v);
        import djs.runtime : runtimeDrainJobs, runtimeRunLoop;
        if (runtimeDrainJobs(self) < 0)
            return false;
        runtimeRunLoop(self);
        return !self.failed;
    }
    // Script entry: the caller evaluates it as a global script.
    return false;
}
