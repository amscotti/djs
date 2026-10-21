module djs.modules.resolve;

import core.stdc.errno : EACCES, ENOENT;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strchr, strlen;

import djs.modules.classify;
import djs.modules.path;
import djs.modules.pkgexports : packageExportsTarget, packageImportsTarget;
import djs.runtime : Runtime;

// One resolution result: either a builtin alias (points at a literal) or a
// canonical path owned by the caller. `err` is 0, ENOENT or EACCES.
struct Resolved
{
    ModuleKind kind = ModuleKind.missing;
    char* path;
    const(char)* builtinAlias;
    int err;
}

private char* concat2(const(char)* a, const(char)* b) @nogc nothrow
{
    size_t la = strlen(a);
    size_t lb = strlen(b);
    char* p = cast(char*) malloc(la + lb + 1);
    if (p is null)
        return null;
    memcpy(p, a, la);
    memcpy(p + la, b, lb + 1);
    return p;
}

// Exact file, then .js/.json/.mjs/.cjs in that order (ARCH §8.0).
private char* probeFile(const(char)* base) @nogc nothrow
{
    if (isFile(base))
        return xstrdup(base);
    // Probe .js/.json/.mjs/.cjs in that order (ARCH §8.0).
    {
        char* c = concat2(base, ".js");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    {
        char* c = concat2(base, ".json");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    {
        char* c = concat2(base, ".mjs");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    {
        char* c = concat2(base, ".cjs");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    return null;
}

private char* probeDirectory(const(char)* dir) @nogc nothrow
{
    char* pkg = pathJoin(dir, "package.json");
    if (pkg !is null)
    {
        char* main = packageJsonValue(pkg, "main");
        free(pkg);
        if (main !is null)
        {
            char* target = pathJoin(dir, main);
            free(main);
            if (target !is null)
            {
                char* found = probeFile(target);
                if (found !is null)
                {
                    free(target);
                    return found;
                }
                if (isDir(target))
                {
                    char* indexed = probeDirectory(target);
                    free(target);
                    if (indexed !is null)
                        return indexed;
                }
                free(target);
            }
        }
    }
    {
        char* c = pathJoin(dir, "index.js");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    {
        char* c = pathJoin(dir, "index.cjs");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    {
        char* c = pathJoin(dir, "index.mjs");
        if (c !is null && isFile(c))
            return c;
        free(c);
    }
    return null;
}

private char* resolveCandidate(const(char)* base) @nogc nothrow
{
    char* found = probeFile(base);
    if (found !is null)
        return found;
    if (isDir(base))
        return probeDirectory(base);
    return null;
}


// Node-style package lookup: walk from the importing directory up to the
// project root, probing <dir>/node_modules/<name>. The package name is the
// first segment, or the first two for a scoped package. Subpaths are resolved
// inside the package directory. `exports` maps are not interpreted yet (the
// package's `main`/index is the entry); see docs/ROADMAP.md.
private Resolved resolveBare(Runtime* self, const(char)* spec, const(char)* baseDir,
                             bool forImport) @nogc nothrow
{
    Resolved r;
    r.err = ENOENT;

    size_t nameLen = 0;
    if (spec[0] == '@')
    {
        const(char)* first = strchr(spec, '/');
        if (first is null || first == spec)
            return r;
        const(char)* second = strchr(first + 1, '/');
        nameLen = second is null ? strlen(spec) : cast(size_t)(second - spec);
    }
    else
    {
        const(char)* slash = strchr(spec, '/');
        nameLen = slash is null ? strlen(spec) : cast(size_t)(slash - spec);
    }
    if (nameLen == 0)
        return r;

    char* name = cast(char*) malloc(nameLen + 1);
    if (name is null)
        return r;
    memcpy(name, spec, nameLen);
    name[nameLen] = 0;
    const(char)* sub = spec + nameLen;

    char* dir = xstrdup(baseDir);
    if (dir is null)
    {
        free(name);
        return r;
    }

    for (;;)
    {
        char* nodeModules = pathJoin(dir, "node_modules");
        char* pkgDir = nodeModules is null ? null : pathJoin(nodeModules, name);
        if (pkgDir !is null && isDir(pkgDir))
        {
            char* found = null;
            char* pkgJson = pathJoin(pkgDir, "package.json");
            char* subKey = null;
            if (sub[0] == 0)
                subKey = xstrdup("");
            else
            {
                size_t sl = strlen(sub);
                subKey = cast(char*) malloc(sl + 2);
                if (subKey !is null)
                {
                    subKey[0] = '.';
                    memcpy(subKey + 1, sub, sl + 1);
                }
            }
            bool hasExports = false;
            char* exported = null;
            if (pkgJson !is null && subKey !is null)
                exported = packageExportsTarget(pkgJson, subKey, forImport, &hasExports);
            free(pkgJson);
            free(subKey);
            if (hasExports)
            {
                if (exported !is null)
                {
                    char* target = concat2(pkgDir, exported + 1); // skip '.'
                    free(exported);
                    if (target !is null)
                    {
                        found = resolveCandidate(target);
                        free(target);
                    }
                }
                // An exports map is authoritative: no main/index fallback.
            }
            else if (sub[0] != 0)
            {
                char* target = concat2(pkgDir, sub);
                if (target !is null)
                {
                    found = resolveCandidate(target);
                    free(target);
                }
            }
            else
            {
                found = probeDirectory(pkgDir);
            }
            free(pkgDir);
            free(nodeModules);
            if (found !is null)
            {
                char* canonical = realPathAlloc(found);
                free(found);
                free(dir);
                free(name);
                if (canonical is null)
                    return r;
                if (!pathWithin(self.rootDir, canonical))
                {
                    free(canonical);
                    r.err = EACCES;
                    return r;
                }
                r.path = canonical;
                r.kind = classifyPath(canonical, self.rootDir);
                if (r.kind == ModuleKind.missing)
                    r.err = ENOENT;
                else
                    r.err = 0;
                return r;
            }
            // Package directory exists but has no usable entry.
            free(dir);
            free(name);
            return r;
        }
        free(pkgDir);
        free(nodeModules);

        char* parent = dirNameAlloc(dir);
        if (parent is null)
            break;
        if (strcmpZ(parent, dir) || !pathWithin(self.rootDir, parent))
        {
            free(parent);
            break;
        }
        free(dir);
        dir = parent;
    }

    free(dir);
    free(name);
    return r;
}

// `#specifier` package imports: find the nearest package.json at or above the
// importing directory, resolve its `imports` map, then resolve the target
// (relative to that package, or as a bare package specifier).
private Resolved resolveImports(Runtime* self, const(char)* spec,
                                const(char)* baseDir, bool forImport) @nogc nothrow
{
    Resolved r;
    r.err = ENOENT;
    char* dir = xstrdup(baseDir);
    if (dir is null)
        return r;
    for (;;)
    {
        char* pkgJson = pathJoin(dir, "package.json");
        if (pkgJson !is null && isFile(pkgJson))
        {
            char* target = packageImportsTarget(pkgJson, spec, forImport);
            free(pkgJson);
            if (target !is null)
            {
                if (target[0] == '.' && target[1] == '/')
                {
                    char* path = concat2(dir, target + 1);
                    free(target);
                    if (path is null)
                        break;
                    char* found = resolveCandidate(path);
                    free(path);
                    if (found !is null)
                    {
                        char* canonical = realPathAlloc(found);
                        free(found);
                        free(dir);
                        if (canonical is null)
                            return r;
                        if (!pathWithin(self.rootDir, canonical))
                        {
                            free(canonical);
                            r.err = EACCES;
                            return r;
                        }
                        r.path = canonical;
                        r.kind = classifyPath(canonical, self.rootDir);
                        if (r.kind == ModuleKind.missing)
                            r.err = ENOENT;
                        else
                            r.err = 0;
                        return r;
                    }
                    break;
                }
                if (target[0] == '#')
                {
                    free(target);
                    break; // chained imports are not supported
                }
                Resolved nested = resolveBare(self, target, dir, forImport);
                free(target);
                free(dir);
                return nested;
            }
        }
        else
            free(pkgJson);
        char* parent = dirNameAlloc(dir);
        if (parent is null)
            break;
        if (strcmpZ(parent, dir) || !pathWithin(self.rootDir, parent))
        {
            free(parent);
            break;
        }
        free(dir);
        dir = parent;
    }
    free(dir);
    return r;
}

Resolved resolveSpec(Runtime* self, const(char)* spec, const(char)* baseDir,
                    bool forImport = false) @nogc nothrow
{
    Resolved r;
    if (spec is null)
    {
        r.err = ENOENT;
        return r;
    }
    const(char)* aliasName = builtinAlias(spec);
    if (aliasName !is null)
    {
        r.kind = ModuleKind.builtin;
        r.builtinAlias = aliasName;
        return r;
    }
    if (spec[0] == '#')
        return resolveImports(self, spec, baseDir, forImport);
    if (!isPathLike(spec))
        return resolveBare(self, spec, baseDir, forImport);
    // `forImport` is carried for package `exports` condition selection; the
    // current resolver does not interpret exports maps yet.
    cast(void) forImport;
    char* candidate = isAbsolutePath(spec) ? xstrdup(spec) : pathJoin(baseDir, spec);
    if (candidate is null)
    {
        r.err = ENOENT;
        return r;
    }
    char* found = resolveCandidate(candidate);
    free(candidate);
    if (found is null)
    {
        r.err = ENOENT;
        return r;
    }
    char* canonical = realPathAlloc(found);
    free(found);
    if (canonical is null)
    {
        r.err = ENOENT;
        return r;
    }
    if (!pathWithin(self.rootDir, canonical))
    {
        free(canonical);
        r.err = EACCES;
        return r;
    }
    r.path = canonical;
    r.kind = classifyPath(canonical, self.rootDir);
    if (r.kind == ModuleKind.missing)
        r.err = ENOENT;
    return r;
}

// The entry file is taken literally (no extension probing) but canonicalized
// and checked against the root exactly like any import.
Resolved resolveEntry(Runtime* self, const(char)* path) @nogc nothrow
{
    Resolved r;
    char* canonical = realPathAlloc(path);
    if (canonical is null)
    {
        r.err = ENOENT;
        return r;
    }
    if (!pathWithin(self.rootDir, canonical))
    {
        free(canonical);
        r.err = EACCES;
        return r;
    }
    r.path = canonical;
    r.kind = classifyPath(canonical, self.rootDir);
    if (r.kind == ModuleKind.missing)
        r.err = ENOENT;
    return r;
}
