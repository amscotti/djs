module djs.modules.classify;

import core.stdc.stdlib : free;
import core.stdc.string : strlen;

import djs.modules.path;

// The one classifier used by the entry point, import and require (ARCH §8.0).
enum ModuleKind
{
    missing,
    esm,
    cjs,
    json,
    builtin,
}

const(char)* builtinAlias(const(char)* spec) @nogc nothrow
{
    if (spec is null)
        return null;
    // One table, not a chain: adding a builtin is one line, and the compiler
    // rejects a duplicate case label instead of silently shadowing it. String
    // switch dispatches on length before content.
    switch (spec[0 .. strlen(spec)])
    {
        case "assert", "node:assert": return "djs:assert";
        case "assert/strict", "node:assert/strict": return "djs:assert_strict";
        case "module", "node:module": return "djs:module";
        case "stream/promises", "node:stream/promises": return "djs:stream_promises";
        case "stream/consumers", "node:stream/consumers": return "djs:stream_consumers";
        case "fs", "node:fs": return "djs:fs";
        case "fs/promises", "node:fs/promises": return "djs:fs/promises";
        case "process", "node:process": return "djs:process";
        case "path", "node:path": return "djs:path";
        case "path/win32", "node:path/win32": return "djs:path_win32";
        case "path/posix", "node:path/posix": return "djs:path_posix";
        case "os", "node:os": return "djs:os";
        case "events", "node:events": return "djs:events";
        case "stream", "node:stream": return "djs:stream";
        case "url", "node:url": return "djs:url";
        case "util", "node:util": return "djs:util";
        case "v8", "node:v8": return "djs:v8";
        case "timers/promises", "node:timers/promises": return "djs:timers/promises";
        case "buffer", "node:buffer": return "djs:buffer";
        case "net", "node:net": return "djs:net";
        case "dns", "node:dns": return "djs:dns";
        case "dns/promises", "node:dns/promises": return "djs:dns_promises";
        case "http", "node:http": return "djs:http";
        case "https", "node:https": return "djs:https";
        case "tls", "node:tls": return "djs:tls";
        case "child_process", "node:child_process": return "djs:child_process";
        case "crypto", "node:crypto": return "djs:crypto";
        case "zlib", "node:zlib": return "djs:zlib";
        case "dgram", "node:dgram": return "djs:dgram";
        case "readline", "node:readline": return "djs:readline";
        case "readline/promises", "node:readline/promises": return "djs:readline_promises";
        case "worker_threads", "node:worker_threads": return "djs:worker_threads";
        case "tty", "node:tty": return "djs:tty";
        case "querystring", "node:querystring": return "djs:querystring";
        case "string_decoder", "node:string_decoder": return "djs:string_decoder";
        case "perf_hooks", "node:perf_hooks": return "djs:perf_hooks";
        case "diagnostics_channel", "node:diagnostics_channel": return "djs:diagnostics_channel";
        case "trace_events", "node:trace_events": return "djs:trace_events";
        case "cluster", "node:cluster": return "djs:cluster";
        case "timers", "node:timers": return "djs:timers";
        case "vm", "node:vm": return "djs:vm";
        case "stream/web", "node:stream/web": return "djs:stream_web";
        case "djs:ws": return "djs:ws";
        case "http2", "node:http2": return "djs:http2";
        default:
            return null;
    }
}

// Classify a canonical path. `root` bounds the package.json walk.
ModuleKind classifyPath(const(char)* canonicalPath, const(char)* root) @nogc nothrow
{
    if (canonicalPath is null)
        return ModuleKind.missing;
    if (hasSuffix(canonicalPath, ".mjs"))
        return ModuleKind.esm;
    if (hasSuffix(canonicalPath, ".cjs"))
        return ModuleKind.cjs;
    if (hasSuffix(canonicalPath, ".json"))
        return ModuleKind.json;
    if (!hasSuffix(canonicalPath, ".js"))
        return ModuleKind.missing;

    char* dir = dirNameAlloc(canonicalPath);
    if (dir is null)
        return ModuleKind.cjs;
    char* pkgDir = nearestPackageDir(dir, root);
    free(dir);
    if (pkgDir is null)
        return ModuleKind.cjs;
    char* pkg = pathJoin(pkgDir, "package.json");
    free(pkgDir);
    if (pkg is null)
        return ModuleKind.cjs;
    char* type = packageJsonValue(pkg, "type");
    free(pkg);
    ModuleKind kind = ModuleKind.cjs;
    if (type !is null)
    {
        if (strcmpZ(type, "module"))
            kind = ModuleKind.esm;
        free(type);
    }
    return kind;
}

bool strcmpZ(const(char)* a, const(char)* b) pure @trusted @nogc nothrow
{
    if (a is null || b is null)
        return false;
    size_t i = 0;
    while (a[i] != 0 && a[i] == b[i])
        i += 1;
    return a[i] == 0 && b[i] == 0;
}

unittest
{
    // The table is the single source of truth for builtin specifiers; the case
    // labels are checked for duplicates by the compiler.
    assert(strcmpZ(builtinAlias("fs"), "djs:fs"));
    assert(strcmpZ(builtinAlias("node:fs"), "djs:fs"));
    assert(strcmpZ(builtinAlias("fs/promises"), "djs:fs/promises"));
    assert(strcmpZ(builtinAlias("node:fs/promises"), "djs:fs/promises"));
    assert(strcmpZ(builtinAlias("dns/promises"), "djs:dns_promises"));
    assert(strcmpZ(builtinAlias("djs:ws"), "djs:ws"));
    assert(builtinAlias("not-a-builtin") is null);
    assert(builtinAlias(null) is null);
}
