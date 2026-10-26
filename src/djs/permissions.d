module djs.permissions;

// Deno-style capability checks. Native code calls permissionCheck before it
// touches the OS; the JS prelude only shapes user-facing objects. Rules live in
// malloc'd memory because this module is used from @nogc paths.

import core.stdc.stdlib : free, malloc, realloc;
import core.sys.posix.sys.types : ssize_t;
import core.sys.posix.unistd : getcwd;
import core.stdc.string : memcmp, memcpy, strlen;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.stat : S_ISLNK, lstat, stat_t;
import core.sys.posix.unistd : readlink;

import djs.bindings.quickjs;
import djs.modules.json : JsonKind, JsonValue, jsonFree, jsonGet, jsonParse;
import djs.modules.path : dirNameAlloc, pathJoin, readFileAlloc, xstrdup;
import djs.bindings.value;

enum Perm : uint
{
    read = 1,
    write = 2,
    env = 4,
    sys = 8,
    net = 16,
    run = 32,
    ffi = 64,
    importPerm = 128,
    listen = 256,
}

private struct Rule
{
    Perm perm;
    char* value;
    bool deny;
}

private Rule* rules;
private size_t ruleCount;
private size_t ruleCap;
private bool allowAll;
private uint revoked;
// Categories the CLI granted or denied explicitly. A CLI flag replaces that
// category's *allow* rules from a -P permission set; deny rules always
// merge. Without this provenance the two sources would silently union,
// which is wider than either configuration alone.
private Perm cliTouched;

void permissionsReset() @nogc nothrow
{
    for (size_t i = 0; i < ruleCount; ++i)
        free(rules[i].value);
    free(rules);
    rules = null;
    ruleCount = 0;
    ruleCap = 0;
    allowAll = false;
    revoked = 0;
    cliTouched = cast(Perm) 0;
}

void permissionsAllowAll() @nogc nothrow
{
    allowAll = true;
}

void permissionsMarkCli(Perm p) @nogc nothrow
{
    cliTouched |= p;
}

// True when the category carries an unscoped grant (`-A`, or a bare
// --allow-run): the sandbox-escape category. Scoped grants must not pass
// a child environment that preloads native code (LD_*/DYLD_*), which would
// execute outside every permission check.
bool permissionUnscoped(Perm p) @nogc nothrow
{
    if (allowAll)
        return true;
    for (size_t i = 0; i < ruleCount; ++i)
    {
        if (rules[i].deny || (rules[i].perm & p) == 0)
            continue;
        if (rules[i].value is null || rules[i].value[0] == 0)
            return true;
    }
    return false;
}

void permissionsRevoke(Perm p) @nogc nothrow
{
    revoked |= p;
}

bool permissionIsRevoked(Perm p) @nogc nothrow
{
    return (revoked & p) != 0;
}

bool permissionsAdd(Perm p, const(char)* value, bool deny) @nogc nothrow
{
    if (ruleCount == ruleCap)
    {
        size_t next = ruleCap == 0 ? 8 : ruleCap * 2;
        Rule* grown = cast(Rule*) realloc(rules, next * Rule.sizeof);
        if (grown is null)
            return false;
        rules = grown;
        ruleCap = next;
    }
    char* copy = null;
    if (value !is null && value[0] != 0)
    {
        size_t n = strlen(value);
        copy = cast(char*) malloc(n + 1);
        if (copy is null)
            return false;
        memcpy(copy, value, n + 1);
    }
    rules[ruleCount].perm = p;
    rules[ruleCount].value = copy;
    rules[ruleCount].deny = deny;
    ruleCount += 1;
    return true;
}

// Resolve symlinks at the leaf (and any symlinked target) before matching.
// `realpath` alone leaves a dangling link unresolved, which would let a write
// through a link planted inside a granted directory escape the grant.
private char* resolveLeafAlloc(const(char)* path) @nogc nothrow
{
    if (path is null)
        return null;
    char* current = xstrdup(path);
    if (current is null)
        return null;
    for (int depth = 0; depth < 16; ++depth)
    {
        stat_t st = void;
        if (lstat(current, &st) != 0)
            return current; // missing leaf: caller canonicalises the parent
        if (!S_ISLNK(st.st_mode))
            return current;
        size_t cap = 256;
        char* target = cast(char*) malloc(cap);
        if (target is null)
        {
            free(current);
            return null;
        }
        ssize_t n = 0;
        for (;;)
        {
            n = readlink(current, target, cap);
            if (n < 0)
            {
                free(target);
                free(current);
                return null;
            }
            if (cast(size_t) n < cap)
                break;
            cap *= 2;
            char* grown = cast(char*) realloc(target, cap);
            if (grown is null)
            {
                free(target);
                free(current);
                return null;
            }
            target = grown;
        }
        target[cast(size_t) n] = 0;
        char* next;
        if (target[0] == '/')
            next = xstrdup(target);
        else
        {
            char* dir = dirNameAlloc(current);
            next = dir is null ? null : pathJoin(dir, target);
            free(dir);
        }
        free(target);
        free(current);
        if (next is null)
            return null;
        current = next;
    }
    // Symlink chain too deep: refuse rather than fall back to a lexical path.
    free(current);
    return null;
}

private char* canonicalAlloc(const(char)* path) @nogc nothrow
{
    char* resolved = resolveLeafAlloc(path);
    if (resolved is null)
        return null;
    char* canon = canonicalAllocRaw(resolved);
    free(resolved);
    return canon;
}

// Lexical/canonical absolute path for matching. Existing paths go through
// realpath; a non-existent tail is appended to the canonicalized parent so a
// new file still matches a granted directory.
private char* canonicalAllocRaw(const(char)* path) @nogc nothrow
{
    if (path is null)
        return null;
    size_t n = strlen(path);
    if (n > 1 && path[n - 1] == '/')
    {
        // A trailing slash must never reach the parent split below: the
        // "parent" of "a/b/" is the identical string "a/b/", and the
        // function would recurse forever (the express static middleware
        // probes directory paths with trailing slashes). Canonical form
        // never keeps a trailing slash.
        size_t keep = n;
        while (keep > 1 && path[keep - 1] == '/')
            keep -= 1;
        char* trimmed = cast(char*) malloc(keep + 1);
        if (trimmed is null)
            return null;
        memcpy(trimmed, path, keep);
        trimmed[keep] = 0;
        char* stripped = canonicalAllocRaw(trimmed);
        free(trimmed);
        return stripped;
    }
    char* canon = realpath(path, null);
    if (canon !is null)
        return canon;

    size_t slash = n;
    while (slash > 0 && path[slash - 1] != '/')
        slash -= 1;
    const(char)* base = path + slash;
    if (slash == 0)
    {
        // Relative single component: resolve the cwd.
        char* cwd = getcwd(null, 0);
        if (cwd is null)
            return null;
        size_t bl = strlen(base);
        char* joined = cast(char*) malloc(strlen(cwd) + 1 + bl + 1);
        if (joined is null)
        {
            free(cwd);
            return null;
        }
        size_t o = 0;
        size_t cl = strlen(cwd);
        memcpy(joined, cwd, cl);
        o = cl;
        joined[o++] = '/';
        memcpy(joined + o, base, bl + 1);
        free(cwd);
        return joined;
    }

    // Canonicalize the parent (strip the trailing slash in a copy).
    char* parent = cast(char*) malloc(slash + 1);
    if (parent is null)
        return null;
    memcpy(parent, path, slash);
    parent[slash] = 0;
    char* canonParent = canonicalAllocRaw(parent);
    free(parent);
    if (canonParent is null)
        return null;
    size_t bl = strlen(base);
    size_t pl = strlen(canonParent);
    char* joined = cast(char*) malloc(pl + 1 + bl + 1);
    if (joined is null)
    {
        free(canonParent);
        return null;
    }
    memcpy(joined, canonParent, pl);
    joined[pl] = '/';
    memcpy(joined + pl + 1, base, bl + 1);
    free(canonParent);
    return joined;
}

// Identity (st_dev, st_ino) of the fully canonicalized path: leaf symlinks
// resolved, so the pair names the inode the permission check actually saw.
// Async fs workers re-verify the fd they open against this pair, closing
// the check-to-open TOCTOU window where a script swaps the leaf for a
// symlink between the check and the worker's open().
// Resolve relative read/write rules against the current working directory.
// The rule matcher canonicalizes at check time, so a process.chdir() without
// this would silently move a grant like --allow-read=./data to the new cwd.
// Called before chdir; failure is fail-closed (the chdir is refused).
bool permissionAbsolutizePathRules() @nogc nothrow
{
    char* cwd = null;
    foreach (ref r; rules[0 .. ruleCount])
    {
        if (r.value is null || r.value[0] == 0 || r.value[0] == '/')
            continue;
        if ((r.perm & (Perm.read | Perm.write)) == 0)
            continue;
        if (cwd is null)
        {
            cwd = getcwd(null, 0);
            if (cwd is null)
                return false;
        }
        char* joined = pathJoin(cwd, r.value);
        if (joined is null)
        {
            free(cwd);
            return false;
        }
        char* canon = canonicalAlloc(joined);
        free(joined);
        if (canon is null)
        {
            free(cwd);
            return false;
        }
        free(r.value);
        r.value = canon;
    }
    free(cwd);
    return true;
}

bool permissionPathIdentity(const(char)* path, long* dev, long* ino) @nogc nothrow
{
    char* canon = canonicalAlloc(path);
    if (canon is null)
        return false;
    stat_t st = void;
    bool ok = lstat(canon, &st) == 0;
    free(canon);
    if (!ok)
        return false;
    *dev = st.st_dev;
    *ino = st.st_ino;
    return true;
}

private bool pathPrefix(const(char)* rule, const(char)* resource) @nogc nothrow
{
    size_t rl = strlen(rule);
    size_t pl = strlen(resource);
    if (rl == 0)
        return true;
    if (rl > pl)
        return false;
    if (memcmp(rule, resource, rl) != 0)
        return false;
    if (rl == pl)
        return true;
    return rule[rl - 1] == '/' || resource[rl] == '/';
}

private bool envMatch(const(char)* pattern, const(char)* name) @nogc nothrow
{
    size_t pl = strlen(pattern);
    size_t nl = strlen(name);
    if (pl == 0)
        return true;
    // One trailing/leading '*' wildcard is enough for --allow-env=API_*.
    if (pattern[0] == '*' && pl > 1)
        return nl >= pl - 1 && !memcmp(name + nl - (pl - 1), pattern + 1, pl - 1);
    if (pattern[pl - 1] == '*' && pl > 1)
        return nl >= pl - 1 && !memcmp(name, pattern, pl - 1);
    return pl == nl && !memcmp(pattern, name, pl);
}

// Host:port match for --allow-net. `rule` may be "*", "host", "host:*",
// "host:port", or "*:port" (IPv6 literals match exactly). A DNS lookup passes
// only a host, so the port part of the rule is ignored for it.
private bool netMatch(const(char)* rule, const(char)* resource) @nogc nothrow
{
    size_t rl = strlen(rule);
    size_t pl = strlen(resource);
    if (rl == 1 && rule[0] == '*')
        return true;
    // Split host and optional :port, with IPv6 bracket support.
    size_t rh = rl, rp = rl;
    size_t ph = pl, pp = pl;
    if (rl > 0 && rule[0] == '[')
    {
        size_t close = 1;
        while (close < rl && rule[close] != ']') close += 1;
        rh = close < rl ? close + 1 : rl;
        if (rh < rl && rule[rh] == ':') { rp = rh + 1; } else rh = rl;
    }
    else
    {
        size_t colon = rl;
        while (colon > 0 && rule[colon - 1] != ':') colon -= 1;
        if (colon > 0) { rh = colon - 1; rp = colon; }
    }
    if (pl > 0 && resource[0] == '[')
    {
        size_t close = 1;
        while (close < pl && resource[close] != ']') close += 1;
        ph = close < pl ? close + 1 : pl;
        if (ph < pl && resource[ph] == ':') pp = ph + 1; else ph = pl;
    }
    else
    {
        size_t colon = pl;
        while (colon > 0 && resource[colon - 1] != ':') colon -= 1;
        if (colon > 0) { ph = colon - 1; pp = colon; }
    }
    bool hostOk = false;
    if (rh == 1 && rule[0] == '*')
        hostOk = true;
    else if (rh > 2 && rule[0] == '*' && rule[1] == '.')
    {
        size_t suffix = rh - 2;
        if (ph > suffix && resource[ph - suffix - 1] == '.')
        {
            hostOk = true;
            for (size_t i = 0; i < suffix; ++i)
            {
                char a = rule[2 + i], b = resource[ph - suffix + i];
                if (a >= 'A' && a <= 'Z') a += 32;
                if (b >= 'A' && b <= 'Z') b += 32;
                if (a != b) { hostOk = false; break; }
            }
        }
    }
    else if (rh == ph)
    {
        hostOk = true;
        for (size_t i = 0; i < rh; ++i)
        {
            char a = rule[i], b = resource[i];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) { hostOk = false; break; }
        }
    }
    if (!hostOk)
        return false;
    if (pp >= pl)
        return true; // resource is a host only (DNS)
    if (rp >= rl)
        return true; // rule has no port: any port
    if (rp < rl && rule[rp] == '*' && rp + 1 == rl)
        return true;
    size_t rulePortLen = rl - rp;
    size_t resPortLen = pl - pp;
    return rulePortLen == resPortLen && memcmp(rule + rp, resource + pp, rulePortLen) == 0;
}

private bool valueMatches(Perm p, const(char)* rule, const(char)* resource) @nogc nothrow
{
    if (rule is null || rule[0] == 0)
        return true;
    if (p == Perm.read || p == Perm.write)
    {
        char* canonRule = canonicalAlloc(rule);
        char* canonRes = canonicalAlloc(resource);
        bool ok = canonRule !is null && canonRes !is null &&
                  pathPrefix(canonRule, canonRes);
        free(canonRule);
        free(canonRes);
        return ok;
    }
    if (p == Perm.env)
        return envMatch(rule, resource is null ? "" : resource);
    if (p == Perm.net || p == Perm.listen)
        return netMatch(rule, resource is null ? "" : resource);
    return resource !is null && strlen(rule) == strlen(resource) &&
           memcmp(rule, resource, strlen(rule)) == 0;
}


private bool addConfigValue(Perm p, JsonValue* v, const(char)* dir, bool deny) @nogc nothrow
{
    if (v is null)
        return true;
    // A CLI flag for this category replaces the set's allows; denies from
    // the set always merge (a config deny cannot be undone by a CLI allow).
    if (!deny && (cliTouched & p) != 0)
        return true;
    if (v.kind == JsonKind.boolValue)
    {
        // `true` grants/denies the whole category; `false` means "nothing
        // in this slot" — it must never widen into an unscoped allow.
        if (v.boolean)
            return permissionsAdd(p, null, deny);
        return true;
    }
    if (v.kind == JsonKind.stringValue)
    {
        char* value = xstrdup(v.string);
        if (value is null)
            return false;
        bool ok = permissionsAdd(p, value, deny);
        free(value);
        return ok;
    }
    if (v.kind == JsonKind.arrayValue)
    {
        for (size_t i = 0; i < v.count; ++i)
        {
            if (v.items[i].kind != JsonKind.stringValue)
                continue;
            char* value = null;
            if (dir !is null && (p == Perm.read || p == Perm.write) &&
                v.items[i].string[0] != '/')
            {
                size_t dl = strlen(dir);
                size_t vl = strlen(v.items[i].string);
                value = cast(char*) malloc(dl + 1 + vl + 1);
                if (value is null)
                    return false;
                memcpy(value, dir, dl);
                value[dl] = '/';
                memcpy(value + dl + 1, v.items[i].string, vl + 1);
            }
            else
                value = xstrdup(v.items[i].string);
            if (value is null)
                return false;
            bool ok = permissionsAdd(p, value, deny);
            free(value);
            if (!ok)
                return false;
        }
        return true;
    }
    return true;
}

bool permissionsLoadConfig(const(char)* path, const(char)* setName) @nogc nothrow
{
    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(path, &src, &len, &err))
        return false;
    JsonValue* root = jsonParse(src, len);
    free(src);
    if (root is null)
        return false;
    JsonValue* perms = jsonGet(root, "permissions");
    const(char)* wanted = (setName is null || setName[0] == 0) ? "default" : setName;
    JsonValue* set = jsonGet(perms, wanted);
    if (set is null || set.kind != JsonKind.objectValue)
    {
        jsonFree(root);
        return false;
    }
    char* dir = dirNameAlloc(path);
    bool ok = true;
    for (size_t i = 0; i < set.count && ok; ++i)
    {
        Perm p = permissionFromName(set.keys[i], strlen(set.keys[i]));
        if (p == cast(Perm) 0)
            continue;
        JsonValue* v = set.items[i];
        if (v.kind == JsonKind.objectValue)
        {
            ok = addConfigValue(p, jsonGet(v, "allow"), dir, false);
            if (ok)
                ok = addConfigValue(p, jsonGet(v, "deny"), dir, true);
            // `ignore` is treated as deny for fs/env until the ignore path has
            // its own semantics; better a closed result than a silent read.
            if (ok)
                ok = addConfigValue(p, jsonGet(v, "ignore"), dir, true);
        }
        else
            ok = addConfigValue(p, v, dir, false);
    }
    free(dir);
    jsonFree(root);
    return ok;
}
private bool promptsEnabled = true;
private int auditFd = -1;
private bool auditInitialised;

void permissionsSetNoPrompt(bool noPrompt) @nogc nothrow
{
    promptsEnabled = !noPrompt;
}

// Opens the audit sink once, at startup. Returns false when the path cannot
// be opened (the caller must abort: a missing audit trail is a failure, not
// a degraded mode). O_NOFOLLOW refuses a pre-planted symlink at the path.
bool permissionsSetAudit(const(char)* path) @nogc nothrow
{
    import core.sys.posix.fcntl : O_APPEND, O_CREAT, O_WRONLY, open;
    import djs.platform : O_CLOEXEC, O_NOFOLLOW;
    if (auditFd >= 0)
    {
        import core.sys.posix.unistd : close;
        close(auditFd);
        auditFd = -1;
    }
    auditInitialised = false;
    if (path is null || path[0] == 0)
        return true;
    auditFd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                   384); // 0600
    if (auditFd < 0)
        return false;
    auditInitialised = true;
    return true;
}

private bool promptFor(Perm p, const(char)* resource) @nogc nothrow
{
    if (!promptsEnabled || resource is null)
        return false;
    import core.sys.posix.unistd : isatty;
    // Prompts need an interactive terminal on both ends: stdin for the
    // answer, stderr for the question. Anything else fails closed.
    if (isatty(0) == 0 || isatty(2) == 0)
        return false;

    import core.stdc.stdio : FILE, fclose, fgets, fopen, fputs;
    import core.stdc.stdlib : free;
    FILE* tty = fopen("/dev/tty", "r+");
    if (tty is null)
        return false;
    fputs("djs: allow ", tty);
    fputs(permissionName(p), tty);
    fputs(" access to ", tty);
    fputs(resource, tty);
    fputs("? [y]es once / [a]lways / [n]o ", tty);
    char[16] answer = void;
    bool yes = false;
    if (fgets(answer.ptr, answer.length, tty) !is null)
    {
        yes = answer[0] == 'y' || answer[0] == 'Y';
        if (!yes && (answer[0] == 'a' || answer[0] == 'A'))
        {
            yes = true;
            // "always" remembers the grant for the rest of the session;
            // "yes" applies to this access only.
            permissionsAdd(p, resource, false);
        }
    }
    fclose(tty);
    return yes;
}

private void auditJsonString(char* dst, size_t* o, size_t cap, const(char)* s) @nogc nothrow
{
    if (s is null)
        return;
    for (size_t i = 0; s[i] && *o + 6 < cap; ++i)
    {
        char c = s[i];
        if (c == '"' || c == '\\')
        {
            dst[(*o)++] = '\\';
            dst[(*o)++] = c;
        }
        else if (c == '\n')
        {
            dst[(*o)++] = '\\';
            dst[(*o)++] = 'n';
        }
        else if (c == '\r')
        {
            dst[(*o)++] = '\\';
            dst[(*o)++] = 'r';
        }
        else if (c == '\t')
        {
            dst[(*o)++] = '\\';
            dst[(*o)++] = 't';
        }
        else if (c >= 0 && c < 0x20)
        {
            // \u00XX escape: 6 bytes, the reason the loop reserves *o + 6.
            dst[(*o)++] = '\\';
            dst[(*o)++] = 'u';
            dst[(*o)++] = '0';
            dst[(*o)++] = '0';
            ubyte h = cast(ubyte) c;
            dst[(*o)++] = cast(char) ((h >> 4) < 10 ? '0' + (h >> 4) : 'a' + (h >> 4) - 10);
            dst[(*o)++] = cast(char) ((h & 0xF) < 10 ? '0' + (h & 0xF) : 'a' + (h & 0xF) - 10);
        }
        else
            dst[(*o)++] = c;
    }
}

private void auditDecision(Perm p, const(char)* resource, bool allowed) @nogc nothrow
{
    if (!auditInitialised)
        return;
    if (auditFd < 0)
        return;

    import core.stdc.time : time;
    import core.sys.posix.unistd : write;

    char[2048] buf = void;
    size_t o = 0;
    const(char)* head = "{\"v\":1,\"time\":";
    size_t hl = strlen(head);
    memcpy(buf.ptr, head, hl);
    o = hl;
    char[32] num = void;
    long t = cast(long) time(null);
    int nl = 0;
    if (t == 0)
        num[0] = '0', nl = 1;
    else
    {
        char[24] rev = void;
        int r = 0;
        while (t > 0 && r < 24)
        {
            rev[r++] = cast(char) ('0' + (t % 10));
            t /= 10;
        }
        while (r > 0)
            num[nl++] = rev[--r];
    }
    memcpy(buf.ptr + o, num.ptr, nl);
    o += nl;
    const(char)* mid = ",\"permission\":\"";
    memcpy(buf.ptr + o, mid, strlen(mid));
    o += strlen(mid);
    const(char)* pn = permissionName(p);
    memcpy(buf.ptr + o, pn, strlen(pn));
    o += strlen(pn);
    const(char)* mid2 = "\",\"value\":\"";
    memcpy(buf.ptr + o, mid2, strlen(mid2));
    o += strlen(mid2);
    // Keep room for the closing tail regardless of how long the value got;
    // auditJsonString may stop early, which only truncates the field.
    enum size_t tailRoom = 24;
    auditJsonString(buf.ptr, &o, buf.length - tailRoom, resource);
    const(char)* tail = allowed ? "\",\"result\":\"allow\"}\n" : "\",\"result\":\"deny\"}\n";
    size_t tl = strlen(tail);
    if (o + tl > buf.length)
        return; // unreachable while tailRoom covers the tail; fail closed anyway
    memcpy(buf.ptr + o, tail, tl);
    o += tl;

    size_t off = 0;
    while (off < o)
    {
        ssize_t n = write(auditFd, buf.ptr + off, o - off);
        if (n <= 0)
            break;
        off += cast(size_t) n;
    }
}

bool permissionCheck(Perm p, const(char)* resource) @nogc nothrow
{
    bool denied = (revoked & p) != 0;
    if (!denied)
    {
        for (size_t i = 0; i < ruleCount; ++i)
            if (rules[i].deny && (rules[i].perm & p) != 0 &&
                valueMatches(p, rules[i].value, resource))
            {
                denied = true;
                break;
            }
    }
    bool allowed = false;
    if (!denied)
    {
        if (allowAll)
            allowed = true;
        else
            for (size_t i = 0; i < ruleCount; ++i)
            {
                if (rules[i].deny || (rules[i].perm & p) == 0)
                    continue;
                if (valueMatches(p, rules[i].value, resource))
                {
                    allowed = true;
                    break;
                }
            }
    }
    // A prompt is offered only when no rule matched at all. An explicit
    // deny rule or a dropped scope is final and must never be overridden
    // from the terminal.
    if (!allowed && !denied)
        allowed = promptFor(p, resource);

    auditDecision(p, resource, allowed);
    return allowed;
}

// True when an explicit deny rule (or a revoked category) covers the
// resource. Callers that consult an alias path use this to keep an explicit
// deny authoritative without issuing a second prompt or audit entry.
bool permissionDenied(Perm p, const(char)* resource) @nogc nothrow
{
    if ((revoked & p) != 0)
        return true;
    for (size_t i = 0; i < ruleCount; ++i)
        if (rules[i].deny && (rules[i].perm & p) != 0 &&
            valueMatches(p, rules[i].value, resource))
            return true;
    return false;
}

// Side-effect-free query for process.permission.has(): the rule verdict
// without prompting, auditing, or caching an interactive grant. A query
// must not change the policy it reports on.
bool permissionHas(Perm p, const(char)* resource) @nogc nothrow
{
    if ((revoked & p) != 0)
        return false;
    for (size_t i = 0; i < ruleCount; ++i)
        if (rules[i].deny && (rules[i].perm & p) != 0 &&
            valueMatches(p, rules[i].value, resource))
            return false;
    if (allowAll)
        return true;
    for (size_t i = 0; i < ruleCount; ++i)
    {
        if (rules[i].deny || (rules[i].perm & p) == 0)
            continue;
        if (valueMatches(p, rules[i].value, resource))
            return true;
    }
    return false;
}

const(char)* permissionName(Perm p) @nogc nothrow
{
    final switch (p)
    {
    case Perm.read: return "read";
    case Perm.write: return "write";
    case Perm.env: return "env";
    case Perm.sys: return "sys";
    case Perm.net: return "net";
    case Perm.run: return "run";
    case Perm.ffi: return "ffi";
    case Perm.importPerm: return "import";
    case Perm.listen: return "listen";
    }
}

Perm permissionFromName(const(char)* name, size_t len) @nogc nothrow
{
    if (len == 0 || name is null)
        return cast(Perm) 0;
    if (len == 4 && !memcmp(name, "read".ptr, 4)) return Perm.read;
    if (len == 5 && !memcmp(name, "write".ptr, 5)) return Perm.write;
    if (len == 3 && !memcmp(name, "env".ptr, 3)) return Perm.env;
    if (len == 3 && !memcmp(name, "sys".ptr, 3)) return Perm.sys;
    if (len == 3 && !memcmp(name, "net".ptr, 3)) return Perm.net;
    if (len == 3 && !memcmp(name, "run".ptr, 3)) return Perm.run;
    if (len == 3 && !memcmp(name, "ffi".ptr, 3)) return Perm.ffi;
    if (len == 6 && !memcmp(name, "listen".ptr, 6)) return Perm.listen;
    if (len == 6 && !memcmp(name, "import".ptr, 6)) return Perm.importPerm;
    return cast(Perm) 0;
}

private void jsSetString(JSContext* ctx, JSValue obj, const(char)* key,
                         const(char)* value) @nogc nothrow
{
    JSValue v = JS_NewStringLen(ctx, value, strlen(value));
    if (!jsIsException(v))
        JS_SetPropertyStr(ctx, obj, key, v);
}

// Build the JS PermissionDenied error value (caller owns it).
JSValue permissionError(JSContext* ctx, Perm p, const(char)* resource) @nogc nothrow
{
    JSValue err = JS_NewError(ctx);
    if (jsIsException(err))
        return err;
    const(char)* name = permissionName(p);
    jsSetString(ctx, err, "name", "PermissionDenied");
    jsSetString(ctx, err, "code", "ERR_ACCESS_DENIED");
    jsSetString(ctx, err, "permission", name);
    if (resource !is null)
        jsSetString(ctx, err, "resource", resource);

    // "Requires --allow-<perm>" or the scoped form. Keep the message short;
    // the fields carry the machine-readable detail.
    char[96] msg = void;
    size_t o = 0;
    const(char)* pre = "Requires --allow-";
    size_t pl = strlen(pre);
    memcpy(msg.ptr, pre, pl);
    o = pl;
    size_t nl = strlen(name);
    memcpy(msg.ptr + o, name, nl);
    o += nl;
    msg[o] = 0;
    JSValue m = JS_NewStringLen(ctx, msg.ptr, o);
    if (jsIsException(m))
    {
        JS_FreeValue(ctx, err);
        return m;
    }
    JS_SetPropertyStr(ctx, err, "message", m);
    return err;
}

// Build and throw; returns the JS exception marker.
JSValue permissionThrow(JSContext* ctx, Perm p, const(char)* resource) @nogc nothrow
{
    return JS_Throw(ctx, permissionError(ctx, p, resource));
}
