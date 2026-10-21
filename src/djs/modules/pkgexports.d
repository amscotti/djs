module djs.modules.pkgexports;

// package.json `exports` / `imports` resolution. Kept separate from the
// generic JSON reader so resolution rules stay in one place. Returns an owned
// package-relative target ("./...") or a bare specifier for `imports`, or null.

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strlen;

import djs.modules.json;
import djs.modules.classify : strcmpZ;
import djs.modules.path : readFileAlloc, xstrdup;

private bool isSubpathKey(const(char)* key) @nogc nothrow
{
    return key !is null && key[0] == '.';
}

private bool memcmpZ(const(char)* a, const(char)* b, size_t n) @nogc nothrow
{
    for (size_t i = 0; i < n; ++i)
        if (a[i] != b[i])
            return false;
    return true;
}

// Node forbids package targets that escape the package ("./../x", absolute).
// Slice core: `..` is only an escape when it is a whole path segment.
private pure @safe @nogc nothrow bool safeRelativeTargetSlice(const(char)[] t)
{
    if (t.length < 2 || t[0] != '.' || t[1] != '/')
        return false;
    foreach (i, c; t)
    {
        if (c != '.')
            continue;
        bool atStart = i == 0 || t[i - 1] == '/';
        if (!atStart)
            continue;
        if (i + 1 < t.length && t[i + 1] == '.' &&
            (i + 2 == t.length || t[i + 2] == '/'))
            return false;
    }
    return true;
}

// Adapter: the only unchecked act is the single strlen.
private @trusted bool safeRelativeTarget(const(char)* t) @nogc nothrow
{
    return t is null ? false : safeRelativeTargetSlice(t[0 .. strlen(t)]);
}

private bool conditionMatches(const(char)* key, bool forImport) @nogc nothrow
{
    if (key is null)
        return false;
    if (strcmpZ(key, "default") || strcmpZ(key, "node"))
        return true;
    if (forImport)
        return strcmpZ(key, "import");
    return strcmpZ(key, "require");
}

private char* resolveTarget(JsonValue* v, bool forImport, int depth) @nogc nothrow
{
    if (v is null || depth > 16)
        return null;
    if (v.kind == JsonKind.stringValue)
        return xstrdup(v.string);
    if (v.kind == JsonKind.arrayValue)
    {
        for (size_t i = 0; i < v.count; ++i)
        {
            char* t = resolveTarget(v.items[i], forImport, depth + 1);
            if (t !is null)
                return t;
        }
        return null;
    }
    if (v.kind == JsonKind.objectValue)
    {
        for (size_t i = 0; i < v.count; ++i)
        {
            if (!conditionMatches(v.keys[i], forImport))
                continue;
            char* t = resolveTarget(v.items[i], forImport, depth + 1);
            if (t !is null)
                return t;
        }
    }
    return null;
}

private char* replaceStars(const(char)* target, const(char)* capture) @nogc nothrow
{
    size_t tl = strlen(target);
    size_t cl = strlen(capture);
    size_t stars = 0;
    for (size_t i = 0; i < tl; ++i)
        if (target[i] == '*')
            stars += 1;
    if (stars == 0)
        return xstrdup(target);
    size_t outLen = tl + stars * (cl > 1 ? cl - 1 : 0);
    char* dst = cast(char*) malloc(outLen + 1);
    if (dst is null)
        return null;
    size_t o = 0;
    for (size_t i = 0; i < tl; ++i)
    {
        if (target[i] == '*')
        {
            memcpy(dst + o, capture, cl);
            o += cl;
        }
        else
            dst[o++] = target[i];
    }
    dst[o] = 0;
    return dst;
}

// Match `sub` ("." or "./x") against a subpath map. Exact keys win, then the
// longest matching `*` pattern (Node's PATTERN_KEY_COMPARE order).
private char* resolveSubpath(JsonValue* map, const(char)* sub, bool forImport) @nogc nothrow
{
    JsonValue* exact = jsonGet(map, sub);
    if (exact !is null)
        return resolveTarget(exact, forImport, 0);

    size_t subLen = strlen(sub);
    size_t bestPrefix = 0;
    JsonValue* best = null;
    const(char)* bestKey = null;
    for (size_t i = 0; i < map.count; ++i)
    {
        const(char)* key = map.keys[i];
        if (key is null || key[0] == 0)
            continue;
        const(char)* star = null;
        for (const(char)* p = key; *p; ++p)
            if (*p == '*')
            {
                star = p;
                break;
            }
        if (star is null)
            continue;
        size_t prefix = cast(size_t)(star - key);
        size_t suffixLen = strlen(star + 1);
        if (prefix > subLen || suffixLen > subLen - prefix)
            continue;
        if (!memcmpZ(key, sub, prefix))
            continue;
        if (suffixLen > 0 && !memcmpZ(sub + subLen - suffixLen, star + 1, suffixLen))
            continue;
        if (best is null || prefix > bestPrefix)
        {
            best = map.items[i];
            bestKey = key;
            bestPrefix = prefix;
        }
    }
    if (best is null)
        return null;
    char* target = resolveTarget(best, forImport, 0);
    if (target is null)
        return null;
    // Capture is the part matched by '*': target prefix is bestKey's prefix.
    size_t capLen = subLen - bestPrefix - (strlen(bestKey + bestPrefix + 1));
    char* capture = cast(char*) malloc(capLen + 1);
    if (capture is null)
    {
        free(target);
        return null;
    }
    memcpy(capture, sub + bestPrefix, capLen);
    capture[capLen] = 0;
    char* expanded = replaceStars(target, capture);
    free(capture);
    free(target);
    return expanded;
}

private char* resolveExportsValue(JsonValue* exports, const(char)* sub, bool forImport) @nogc nothrow
{
    if (exports is null)
        return null;
    if (exports.kind == JsonKind.stringValue || exports.kind == JsonKind.arrayValue)
    {
        if (sub[0] != 0 && !(sub[0] == '.' && sub[1] == 0))
            return null;
        return resolveTarget(exports, forImport, 0);
    }
    if (exports.kind != JsonKind.objectValue)
        return null;
    bool subpathMap = false;
    for (size_t i = 0; i < exports.count; ++i)
        if (isSubpathKey(exports.keys[i]))
        {
            subpathMap = true;
            break;
        }
    if (subpathMap)
    {
        // "." is the root subpath; callers pass "" for the package root.
        const(char)* key = (sub[0] == 0) ? "." : sub;
        return resolveSubpath(exports, key, forImport);
    }
    if (sub[0] != 0)
        return null;
    return resolveTarget(exports, forImport, 0);
}

// Read package.json and resolve `sub` ("" for root, "./x" otherwise).
// Returns a package-relative target or null when not exported.
char* packageExportsTarget(const(char)* pkgJsonPath, const(char)* sub,
                           bool forImport, bool* present = null) @nogc nothrow
{
    if (present !is null)
        *present = false;
    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(pkgJsonPath, &src, &len, &err))
        return null;
    JsonValue* root = jsonParse(src, len);
    free(src);
    if (root is null)
        return null;
    JsonValue* exports = jsonGet(root, "exports");
    if (present !is null)
        *present = exports !is null;
    char* target = resolveExportsValue(exports, sub, forImport);
    jsonFree(root);
    if (target is null)
        return null;
    if (!safeRelativeTarget(target))
    {
        free(target);
        return null;
    }
    return target;
}

// `#specifier` imports. Relative targets are returned as "./..."; bare
// targets are returned as-is for the caller to resolve as a package.
char* packageImportsTarget(const(char)* pkgJsonPath, const(char)* spec,
                           bool forImport) @nogc nothrow
{
    if (spec is null || spec[0] != '#')
        return null;
    char* src = null;
    size_t len = 0;
    int err = 0;
    if (!readFileAlloc(pkgJsonPath, &src, &len, &err))
        return null;
    JsonValue* root = jsonParse(src, len);
    free(src);
    if (root is null)
        return null;
    JsonValue* imports = jsonGet(root, "imports");
    char* target = null;
    if (imports !is null && imports.kind == JsonKind.objectValue)
        target = resolveSubpath(imports, spec, forImport);
    jsonFree(root);
    if (target is null)
        return null;
    if (target[0] == '.' && !safeRelativeTarget(target))
    {
        free(target);
        return null;
    }
    // A bare package target is valid for `imports`; keep it. Chained `#`
    // targets are rejected by the caller.
    return target;
}

@safe unittest
{
    assert(safeRelativeTargetSlice("./a"));
    assert(safeRelativeTargetSlice("./a/b.js"));
    assert(safeRelativeTargetSlice("./a.b"));       // a dot in a name is fine
    assert(safeRelativeTargetSlice("./a/..b"));     // so is a dot-prefixed name
    assert(safeRelativeTargetSlice("./"));
    assert(!safeRelativeTargetSlice("../a"));       // not package-relative
    assert(!safeRelativeTargetSlice("./../a"));     // escapes
    assert(!safeRelativeTargetSlice("./a/../b"));   // escapes mid-path
    assert(!safeRelativeTargetSlice("./a/.."));
    assert(!safeRelativeTargetSlice("/abs"));
    assert(!safeRelativeTargetSlice("."));          // used to read past the NUL
}
