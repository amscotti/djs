module djs.main;

import std.file : readText;
import std.path : dirName;
import std.stdio : stdin;
import std.string : indexOf, toStringz;

import core.stdc.stdlib : free, getenv;
import core.stdc.string : strlen;

import djs.bindings.quickjs;
import djs.bindings.value;
import djs.modules.classify : ModuleKind, classifyPath;
import djs.modules.esm : runEntry;
import djs.modules.path : dirNameAlloc, hasSuffix, projectRootFor;
import djs.modules.resolve : Resolved, resolveEntry;
import djs.permissions;
import djs.runtime;

private void println(const(char)* s, size_t len)
{
    writeFd(1, s, len);
    writeFd(1, "\n", 1);
}

private void usage()
{
    writeLiteral(1, "usage: djs [options] [file.js] [args...]\n");
    writeLiteral(1, "  djs -e <code>            evaluate a string\n");
    writeLiteral(1, "  djs <file>               run a script or module\n");
    writeLiteral(1, "  djs                      start a REPL\n");
    writeLiteral(1, "  --timeout <ms>           stop after a deadline\n");
    writeLiteral(1, "  --memory-limit <bytes>   QuickJS heap limit (default 256 MiB)\n");
    writeLiteral(1, "  --stack-size <bytes>     JS stack limit (default 1 MiB)\n");
    writeLiteral(1, "  -A, --allow-all          disable permission checks (legacy behaviour)\n");
    writeLiteral(1, "  --allow-read[=paths]     grant read access (comma separated)\n");
    writeLiteral(1, "  --allow-write[=paths]    grant write access\n");
    writeLiteral(1, "  --allow-env[=names]      grant environment access\n");
    writeLiteral(1, "  --allow-sys[=names]      grant host facts (hostname, cpus, memory, release)\n");
    writeLiteral(1, "  --allow-net[=host:port]  grant outbound TCP/UDP/DNS\n");
    writeLiteral(1, "  --allow-run[=cmds]       grant child processes\n");
    writeLiteral(1, "  --allow-listen[=host:port]  accept inbound TCP connections\n");
    writeLiteral(1, "  --deny-<perm>[=values]   deny wins over grants and -A\n");
    writeLiteral(1, "  -R/-W/-E/-N/-S           short forms of read/write/env/net/sys\n");
    writeLiteral(1, "  -P[=set], --permission-set[=set]  load a permission set from the config\n");
    writeLiteral(1, "  --config <path>          config file for permission sets (default djs.json)\n");
    writeLiteral(1, "  --no-prompt              never ask; denied access fails closed\n");
    writeLiteral(1, "  -v, --version            print the version\n");
    writeLiteral(1, "  -h, --help               print this help\n");
}

private int repl(Runtime* rt)
{
    writeFd(1, "> ", 2);
    foreach (line; stdin.byLine())
    {
        if (line.length > 0)
        {
            JSValue result = jsUndefined();
            EvalResult er = runtimeEval(rt, line.ptr, line.length, "<repl>", &result);
            if (er == EvalResult.exception)
            {
                runtimePrintException(rt, rt.ctx);
                JS_FreeValue(rt.ctx, result);
            }
            else
            {
                if (!jsIsUndefined(result))
                {
                    size_t len = 0;
                    const(char)* text = JS_ToCStringLen2(rt.ctx, &len, result, false);
                    if (text !is null)
                    {
                        println(text, len);
                        JS_FreeCString(rt.ctx, text);
                    }
                    else if (JS_HasException(rt.ctx))
                    {
                        runtimePrintException(rt, rt.ctx);
                    }
                }
                JS_FreeValue(rt.ctx, result);
            }
            // Ready timers/microtasks run before the next prompt; future
            // events wait for the next line instead of blocking the REPL.
            runtimePump(rt);
            if (rt.failed)
            {
                // A REPL reports and continues instead of exiting.
                rt.failed = false;
                rt.exitCode = 0;
            }
        }
        writeFd(1, "> ", 2);
    }
    writeFd(1, "\n", 1);
    // EOF: teardown closes live timers instead of waiting for them.
    return rt.exitCode;
}

private bool parseLong(string s, long* result)
{
    long v = 0;
    bool any = false;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        v = v * 10 + (c - '0');
        if (v < 0)
            return false;
        any = true;
    }
    if (!any)
        return false;
    *result = v;
    return true;
}

private int runMain(string[] args)
{
    RuntimeOptions opts;
    int argStart = 1;
    string evalCode;
    bool haveEval = false;
    bool wantConfig = false;
    string configPath = "djs.json";
    string configSet = "";

    permissionsReset();
    if (!permissionsSetAudit(getenv("DJS_AUDIT_PERMISSIONS")))
    {
        writeLiteral(2, "djs: cannot open DJS_AUDIT_PERMISSIONS file\n");
        return 1;
    }
    while (argStart < args.length)
    {
        string a = args[argStart];
        if (a == "-A" || a == "--allow-all")
        {
            permissionsAllowAll();
            argStart += 1;
            continue;
        }
        if (a == "--no-prompt")
        {
            permissionsSetNoPrompt(true);
            argStart += 1;
            continue;
        }
        if (a == "-P" || a == "--permission-set")
        {
            wantConfig = true;
            argStart += 1;
            continue;
        }
        if (a.length > 3 && a[0 .. 3] == "-P=")
        {
            wantConfig = true;
            configSet = a[3 .. $];
            argStart += 1;
            continue;
        }
        if (a.length > 16 && a[0 .. 16] == "--permission-set")
        {
            wantConfig = true;
            if (a.length > 17 && a[16] == '=')
                configSet = a[17 .. $];
            argStart += 1;
            continue;
        }
        if (a == "--config")
        {
            if (argStart + 1 >= args.length)
            {
                writeLiteral(2, "djs: --config requires a path\n");
                return 1;
            }
            configPath = args[argStart + 1];
            // Naming a config file is a request to use it; previously the path
            // was only read when -P was also given, so the flag did nothing.
            wantConfig = true;
            argStart += 2;
            continue;
        }
        if (a.length > 2 && a[0 .. 2] == "--")
        {
            bool deny = a.length > 7 && a[0 .. 7] == "--deny-";
            bool allow = a.length > 8 && a[0 .. 8] == "--allow-";
            if (allow || deny)
            {
                string body = a[(deny ? 7 : 8) .. $];
                size_t eq = body.indexOf('=');
                string name = eq == size_t.max ? body : body[0 .. eq];
                string value = eq == size_t.max ? "" : body[eq + 1 .. $];
                Perm p = permissionFromName(name.ptr, name.length);
                if (p == cast(Perm) 0)
                {
                    writeLiteral(2, "djs: unknown permission category\n");
                    return 1;
                }
                if (eq != size_t.max && value.length == 0)
                {
                    // `--allow-read=` (explicit equals, empty list) is a
                    // startup error, never a silent whole-category grant.
                    writeLiteral(2, "djs: empty value for permission flag: ");
                    writeFd(2, a.ptr, a.length);
                    writeLiteral(2, "\n");
                    return 1;
                }
                if (value.length == 0)
                {
                    if (!permissionsAdd(p, null, deny))
                        return 1;
                }
                else
                {
                    size_t start = 0;
                    while (start <= value.length)
                    {
                        size_t comma = start;
                        while (comma < value.length && value[comma] != ',')
                            comma += 1;
                        string piece = value[start .. comma];
                        if (piece.length > 0)
                        {
                            auto z = toStringz(piece);
                            if (!permissionsAdd(p, z, deny))
                                return 1;
                        }
                        if (comma == value.length)
                            break;
                        start = comma + 1;
                    }
                }
                argStart += 1;
                continue;
            }
        }
        if (a == "--help" || a == "-h")
        {
            usage();
            return 0;
        }
        if (a == "--version" || a == "-v")
        {
            println(djsVersion.ptr, djsVersion.length);
            return 0;
        }
        if (a == "--timeout" || a == "--memory-limit" || a == "--stack-size")
        {
            if (argStart + 1 >= args.length)
            {
                writeLiteral(2, "djs: option requires a value\n");
                return 1;
            }
            long v = 0;
            if (!parseLong(args[argStart + 1], &v) || v <= 0)
            {
                writeLiteral(2, "djs: option value must be a positive integer\n");
                return 1;
            }
            if (a == "--timeout")
                opts.timeoutMs = v;
            else if (a == "--memory-limit")
                opts.memoryLimit = cast(size_t) v;
            else
                opts.stackSize = cast(size_t) v;
            argStart += 2;
            continue;
        }
        if (a == "-e" || a == "--eval")
        {
            if (argStart + 1 >= args.length)
            {
                writeLiteral(2, "djs: -e requires a code argument\n");
                return 1;
            }
            evalCode = args[argStart + 1];
            haveEval = true;
            argStart += 2;
            break;
        }
        if (a.length >= 2 && a[0] == '-')
        {
            Perm shortPerm = cast(Perm) 0;
            switch (a[1])
            {
            case 'R': shortPerm = Perm.read; break;
            case 'W': shortPerm = Perm.write; break;
            case 'E': shortPerm = Perm.env; break;
            case 'N': shortPerm = Perm.net; break;
            case 'S': shortPerm = Perm.sys; break;
            default: break;
            }
            if (shortPerm != cast(Perm) 0)
            {
                bool hasEq = a.length >= 3 && a[2] == '=';
                string value = hasEq ? a[3 .. $] : "";
                if (hasEq && value.length == 0)
                {
                    writeLiteral(2, "djs: empty value for permission flag: ");
                    writeFd(2, a.ptr, a.length);
                    writeLiteral(2, "\n");
                    return 1;
                }
                if (value.length == 0)
                {
                    if (!permissionsAdd(shortPerm, null, false))
                        return 1;
                }
                else
                {
                    size_t start = 0;
                    while (start <= value.length)
                    {
                        size_t comma = start;
                        while (comma < value.length && value[comma] != ',')
                            comma += 1;
                        string piece = value[start .. comma];
                        if (piece.length > 0)
                        {
                            auto z = toStringz(piece);
                            if (!permissionsAdd(shortPerm, z, false))
                                return 1;
                        }
                        if (comma == value.length)
                            break;
                        start = comma + 1;
                    }
                }
                argStart += 1;
                continue;
            }
        }
        if (a.length > 0 && a[0] == '-')
        {
            writeFd(2, "djs: unknown option ", 20);
            writeFd(2, a.ptr, a.length);
            writeFd(2, "\n", 1);
            return 1;
        }
        break;
    }

    string entry;
    if (!haveEval && argStart < args.length)
        entry = args[argStart];

    // argv is the runtime name plus the entry and its arguments; for -e the
    // code string is not part of argv (matching Node's -e shape).
    string[] jsArgs;
    jsArgs ~= "djs";
    if (!haveEval)
    {
        foreach (i; argStart .. args.length)
            jsArgs ~= args[i];
    }

    if (entry.length > 0)
    {
        // Symlinks must not decide the root: canonicalize first, then widen to
        // the package that owns the entry so subdirectories classify like Node.
        auto zentry = toStringz(entry);
        char* root = projectRootFor(zentry);
        if (root !is null)
        {
            opts.entryDir = root[0 .. strlen(root)].idup;
            free(root);
        }
        else
        {
            opts.entryDir = dirName(entry);
        }
    }
    else
        opts.entryDir = "";

    if (wantConfig)
    {
        auto cpath = toStringz(configPath);
        auto cset = configSet.length > 0 ? toStringz(configSet) : null;
        if (!permissionsLoadConfig(cpath, cset))
        {
            writeFd(2, "djs: cannot load permission set ", 32);
            writeFd(2, configPath.ptr, configPath.length);
            writeFd(2, "\n", 1);
            return 1;
        }
    }

    Runtime* rt = runtimeCreate(jsArgs, opts);
    if (rt is null)
        return 70;
    if (!runtimeInstallPrelude(rt))
        return runtimeTeardown(rt);

    if (haveEval)
    {
        runtimeRunScript(rt, evalCode.ptr, evalCode.length, "<eval>");
    }
    else if (entry.length > 0)
    {
        auto zpath = toStringz(entry);
        Resolved r = resolveEntry(rt, zpath);
        if (r.err != 0)
        {
            writeFd(2, "djs: cannot read ", 17);
            writeFd(2, entry.ptr, entry.length);
            writeFd(2, "\n", 1);
            rt.exitCode = 1;
            rt.failed = true;
            return runtimeTeardown(rt);
        }
        // Every CommonJS entry runs through the module wrapper so top-level
        // `var` stays module-scoped and module/exports/require are arguments.
        if (r.kind == ModuleKind.json)
        {
            writeLiteral(2, "djs: a JSON file is not an executable entry\n");
            rt.exitCode = 1;
            rt.failed = true;
        }
        else
        {
            runEntry(rt, r.path, r.kind, false);
        }
        // r.path is malloc'd by the resolver.
        import core.stdc.stdlib : free;
        free(r.path);
    }
    else
    {
        repl(rt);
    }

    return runtimeTeardown(rt);
}

int main(string[] args)
{
    try
    {
        return runMain(args);
    }
    catch (Throwable t)
    {
        // The outermost frame is the only place a D Error is allowed to stop
        // the process. It never crosses back into QuickJS or libuv.
        writeLiteral(2, "djs: internal error\n");
        return 70;
    }
}
