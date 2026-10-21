module djs.registry;

import core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memset;
import djs.bindings.quickjs;

// A callback slot is the only bridge from a libuv completion to a JavaScript
// function. Slots are C-allocated (never GC memory), generation-checked, and
// own exactly one reference to their function. Ids are (generation << 32) |
// index, so a stale id is rejected without dereferencing anything.
struct CallbackSlot
{
    JSValue fn;
    ulong generation;
    uint state; // 0 free, 1 active, 2 cancelled
    uint nextFree;
    void* user;
}

enum uint slotFree = 0;
enum uint slotActive = 1;

struct CallbackRegistry
{
    CallbackSlot* slots;
    uint capacity;
    uint freeHead; // 1-based index into slots; 0 means empty
    bool ready;
}

bool registryInit(CallbackRegistry* reg, uint capacity) @nogc nothrow
{
    if (capacity < 4)
        capacity = 4;
    reg.slots = cast(CallbackSlot*) calloc(capacity, CallbackSlot.sizeof);
    if (reg.slots is null)
        return false;
    reg.capacity = capacity;
    reg.ready = true;
    for (uint i = 0; i < capacity; ++i)
    {
        reg.slots[i].state = slotFree;
        reg.slots[i].fn = jsUndefined();
        reg.slots[i].nextFree = (i + 1 < capacity) ? i + 2 : 0;
    }
    reg.freeHead = 1;
    return true;
}

void registryDestroy(CallbackRegistry* reg) @nogc nothrow
{
    if (reg.slots !is null)
        free(reg.slots);
    reg.slots = null;
    reg.capacity = 0;
    reg.freeHead = 0;
    reg.ready = false;
}

private bool registryGrow(CallbackRegistry* reg) @nogc nothrow
{
    uint oldCap = reg.capacity;
    uint newCap = oldCap * 2;
    if (newCap <= oldCap)
        return false;
    CallbackSlot* p = cast(CallbackSlot*) realloc(reg.slots,
                                                  newCap * CallbackSlot.sizeof);
    if (p is null)
        return false;
    reg.slots = p;
    memset(p + oldCap, 0, (newCap - oldCap) * CallbackSlot.sizeof);
    for (uint i = oldCap; i < newCap; ++i)
    {
        p[i].state = slotFree;
        p[i].fn = jsUndefined();
        p[i].nextFree = (i + 1 < newCap) ? i + 2 : 0;
    }
    // Splice the new range in front of the existing free list.
    p[newCap - 1].nextFree = reg.freeHead;
    reg.freeHead = oldCap + 1;
    reg.capacity = newCap;
    return true;
}

ulong registryAdd(JSContext* ctx, CallbackRegistry* reg, JSValueConst fn,
                  void* user) @nogc nothrow
{
    if (!reg.ready)
        return 0;
    if (reg.freeHead == 0 && !registryGrow(reg))
        return 0;
    uint index = reg.freeHead - 1;
    CallbackSlot* slot = &reg.slots[index];
    reg.freeHead = slot.nextFree;
    slot.nextFree = 0;
    slot.generation += 1;
    if (slot.generation == 0)
        slot.generation = 1;
    slot.state = slotActive;
    slot.fn = JS_DupValue(ctx, fn);
    slot.user = user;
    return (slot.generation << 32) | index;
}

CallbackSlot* registryLookup(CallbackRegistry* reg, ulong id) @nogc nothrow
{
    if (!reg.ready || id == 0)
        return null;
    uint index = cast(uint) (id & 0xffffffff);
    uint generation = cast(uint) (id >> 32);
    if (index >= reg.capacity)
        return null;
    CallbackSlot* slot = &reg.slots[index];
    if (slot.state != slotActive || slot.generation != generation)
        return null;
    return slot;
}

void* registryUser(CallbackRegistry* reg, ulong id) @nogc nothrow
{
    CallbackSlot* slot = registryLookup(reg, id);
    return slot is null ? null : slot.user;
}

void registryRelease(JSContext* ctx, CallbackRegistry* reg, ulong id) @nogc nothrow
{
    CallbackSlot* slot = registryLookup(reg, id);
    if (slot is null)
        return;
    JS_FreeValue(ctx, slot.fn);
    slot.fn = jsUndefined();
    slot.state = slotFree;
    slot.user = null;
    slot.generation += 1;
    if (slot.generation == 0)
        slot.generation = 1;
    slot.nextFree = reg.freeHead;
    reg.freeHead = cast(uint) (id & 0xffffffff) + 1;
}

// Transfer the function reference out of the registry. The caller becomes the
// owner and must free it. Returns false for stale or cancelled ids.
bool registryDetach(JSContext* ctx, CallbackRegistry* reg, ulong id,
                    JSValue* outFn, void** outUser) @nogc nothrow
{
    CallbackSlot* slot = registryLookup(reg, id);
    if (slot is null)
        return false;
    *outFn = slot.fn;
    if (outUser !is null)
        *outUser = slot.user;
    slot.fn = jsUndefined();
    slot.state = slotFree;
    slot.user = null;
    slot.generation += 1;
    if (slot.generation == 0)
        slot.generation = 1;
    slot.nextFree = reg.freeHead;
    reg.freeHead = cast(uint) (id & 0xffffffff) + 1;
    return true;
}

// Release every JSValue still held by the registry. Called during teardown,
// before JS_FreeContext.
void registryFreeAll(JSContext* ctx, CallbackRegistry* reg) @nogc nothrow
{
    if (!reg.ready)
        return;
    for (uint i = 0; i < reg.capacity; ++i)
    {
        CallbackSlot* slot = &reg.slots[i];
        if (slot.state == slotActive)
            JS_FreeValue(ctx, slot.fn);
        slot.fn = jsUndefined();
        slot.state = slotFree;
        slot.user = null;
    }
    reg.freeHead = 0;
}

unittest
{
    import djs.bindings.quickjs : JS_NewRuntime, JS_NewContext, JS_FreeContext,
        JS_FreeRuntime, jsUndefined;

    CallbackRegistry reg;
    assert(registryInit(&reg, 4));
    assert(reg.capacity == 4);

    JSRuntime* rt = JS_NewRuntime();
    assert(rt !is null);
    JSContext* ctx = JS_NewContext(rt);
    assert(ctx !is null);

    JSValue fn = jsUndefined();
    ulong id1 = registryAdd(ctx, &reg, fn, cast(void*) 0x1);
    ulong id2 = registryAdd(ctx, &reg, fn, cast(void*) 0x2);
    assert(id1 != 0 && id2 != 0 && id1 != id2);
    assert(registryLookup(&reg, id1) !is null);
    assert(registryUser(&reg, id2) is cast(void*) 0x2);

    registryRelease(ctx, &reg, id1);
    assert(registryLookup(&reg, id1) is null);

    ulong id3 = registryAdd(ctx, &reg, fn, cast(void*) 0x3);
    assert((id3 & 0xffffffff) == (id1 & 0xffffffff));
    assert((id3 >> 32) != (id1 >> 32));
    assert(registryLookup(&reg, id1) is null);
    assert(registryUser(&reg, id3) is cast(void*) 0x3);

    // Force growth past the initial capacity.
    ulong[8] ids;
    foreach (i; 0 .. 8)
        ids[i] = registryAdd(ctx, &reg, fn, cast(void*) (0x10 + i));
    foreach (id; ids)
        assert(id != 0);

    registryFreeAll(ctx, &reg);
    registryDestroy(&reg);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
}
