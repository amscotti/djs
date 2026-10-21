module djs.bindings.quickjs;

// C declarations for the pinned QuickJS-NG public API. No layout is mirrored
// here except JSValue, whose size and alignment are asserted below and probed
// independently by scripts/bootstrap.sh.
extern(C):

struct JSRuntime;
struct JSContext;
struct JSObject;

alias JSClassID = uint;
alias JSAtom = uint;

union JSValueUnion
{
    int int32;
    double float64;
    void* ptr;
    int short_big_int;
}

struct JSValue
{
    JSValueUnion u;
    long tag;
}

alias JSValueConst = JSValue;

static assert(JSValue.sizeof == 16);
static assert(JSValue.alignof == 8);

enum : int
{
    JS_TAG_FIRST = -9,
    JS_TAG_BIG_INT = -9,
    JS_TAG_SYMBOL = -8,
    JS_TAG_STRING = -7,
    JS_TAG_STRING_ROPE = -6,
    JS_TAG_MODULE = -3,
    JS_TAG_FUNCTION_BYTECODE = -2,
    JS_TAG_OBJECT = -1,

    JS_TAG_INT = 0,
    JS_TAG_BOOL = 1,
    JS_TAG_NULL = 2,
    JS_TAG_UNDEFINED = 3,
    JS_TAG_UNINITIALIZED = 4,
    JS_TAG_CATCH_OFFSET = 5,
    JS_TAG_EXCEPTION = 6,
    JS_TAG_SHORT_BIG_INT = 7,
    JS_TAG_FLOAT64 = 8,
}

enum
{
    JS_EVAL_TYPE_GLOBAL = 0,
    JS_EVAL_TYPE_MODULE = 1,

    JS_EVAL_FLAG_STRICT = 1 << 3,
    JS_EVAL_FLAG_COMPILE_ONLY = 1 << 5,
    JS_EVAL_FLAG_BACKTRACE_BARRIER = 1 << 6,
    JS_EVAL_FLAG_ASYNC = 1 << 7,

    JS_CFUNC_generic = 0,
    JS_CFUNC_generic_magic = 1,
}

// Special values. The tag sits in the second field; the union is zeroed.
JSValue jsUndefined() @nogc nothrow
{
    JSValue v;
    v.u.int32 = 0;
    v.tag = JS_TAG_UNDEFINED;
    return v;
}

JSValue jsNull() @nogc nothrow
{
    JSValue v;
    v.u.int32 = 0;
    v.tag = JS_TAG_NULL;
    return v;
}

JSValue jsBool(bool b) @nogc nothrow
{
    JSValue v;
    v.u.int32 = b ? 1 : 0;
    v.tag = JS_TAG_BOOL;
    return v;
}

JSValue jsInt(int i) @nogc nothrow
{
    JSValue v;
    v.u.int32 = i;
    v.tag = JS_TAG_INT;
    return v;
}

JSValue jsFloat(double d) @nogc nothrow
{
    JSValue v;
    v.u.float64 = d;
    v.tag = JS_TAG_FLOAT64;
    return v;
}

bool jsIsException(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_EXCEPTION;
}

bool jsIsUndefined(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_UNDEFINED;
}

bool jsIsNull(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_NULL;
}

bool jsIsObject(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_OBJECT;
}

bool jsIsNumber(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_INT || v.tag == JS_TAG_FLOAT64
        || v.tag == JS_TAG_SHORT_BIG_INT;
}

bool jsIsBigInt(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_BIG_INT || v.tag == JS_TAG_SHORT_BIG_INT;
}

bool jsIsSymbol(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_SYMBOL;
}

bool jsSamePointer(JSValueConst a, JSValueConst b) @nogc nothrow
{
    return a.tag == b.tag && a.u.ptr is b.u.ptr;
}

alias JSCFunction = extern(C) JSValue function(JSContext* ctx, JSValueConst thisVal,
                                               int argc, JSValueConst* argv) nothrow @nogc;
alias JSCFunctionData = extern(C) JSValue function(JSContext* ctx, JSValueConst thisVal,
                                                   int argc, JSValueConst* argv,
                                                   int magic, JSValue* funcData) nothrow @nogc;
alias JSHostPromiseRejectionTracker = extern(C) void function(JSContext* ctx,
                                                              JSValueConst promise,
                                                              JSValueConst reason,
                                                              bool isHandled,
                                                              void* opaque) nothrow @nogc;
alias JSJobFunc = extern(C) JSValue function(JSContext* ctx, int argc,
                                             JSValueConst* argv) nothrow @nogc;
alias JSInterruptHandler = extern(C) int function(JSRuntime* rt, void* opaque) nothrow @nogc;

JSRuntime* JS_NewRuntime() nothrow @nogc;
void JS_FreeRuntime(JSRuntime* rt) nothrow @nogc;
JSContext* JS_NewContext(JSRuntime* rt) nothrow @nogc;
void JS_FreeContext(JSContext* ctx) nothrow @nogc;
void JS_SetMemoryLimit(JSRuntime* rt, size_t limit) nothrow @nogc;
void JS_SetMaxStackSize(JSRuntime* rt, size_t stackSize) nothrow @nogc;
void JS_SetCanBlock(JSRuntime* rt, bool canBlock) nothrow @nogc;
void JS_SetInterruptHandler(JSRuntime* rt, JSInterruptHandler cb, void* opaque) nothrow @nogc;

void* JS_GetContextOpaque(JSContext* ctx) nothrow @nogc;
void JS_SetContextOpaque(JSContext* ctx, void* opaque) nothrow @nogc;
JSRuntime* JS_GetRuntime(JSContext* ctx) nothrow @nogc;
const(char)* JS_GetVersion() nothrow @nogc;

JSValue JS_GetGlobalObject(JSContext* ctx) nothrow @nogc;
JSValue JS_Eval(JSContext* ctx, const(char)* input, size_t inputLen,
                const(char)* filename, int evalFlags) nothrow @nogc;
JSValue JS_Call(JSContext* ctx, JSValueConst funcObj, JSValueConst thisObj,
                int argc, JSValueConst* argv) nothrow @nogc;

JSValue JS_GetException(JSContext* ctx) nothrow @nogc;
bool JS_HasException(JSContext* ctx) nothrow @nogc;
bool JS_IsError(JSValueConst val) nothrow @nogc;
bool JS_IsUncatchableError(JSValueConst val) nothrow @nogc;
JSValue JS_Throw(JSContext* ctx, JSValue obj) nothrow @nogc;
JSValue JS_NewError(JSContext* ctx) nothrow @nogc;
JSValue JS_ThrowTypeError(JSContext* ctx, const(char)* fmt, ...) nothrow @nogc;
JSValue JS_ThrowRangeError(JSContext* ctx, const(char)* fmt, ...) nothrow @nogc;
JSValue JS_ThrowInternalError(JSContext* ctx, const(char)* fmt, ...) nothrow @nogc;
JSValue JS_ThrowSyntaxError(JSContext* ctx, const(char)* fmt, ...) nothrow @nogc;

void JS_FreeValue(JSContext* ctx, JSValue v) nothrow @nogc;
void JS_FreeValueRT(JSRuntime* rt, JSValue v) nothrow @nogc;
JSValue JS_DupValue(JSContext* ctx, JSValueConst v) nothrow @nogc;

int JS_ToBool(JSContext* ctx, JSValueConst val) nothrow @nogc;
int JS_ToInt32(JSContext* ctx, int* pres, JSValueConst val) nothrow @nogc;
int JS_ToFloat64(JSContext* ctx, double* pres, JSValueConst val) nothrow @nogc;

JSValue JS_NewNumber(JSContext* ctx, double d) nothrow @nogc;
JSValue JS_NewStringLen(JSContext* ctx, const(char)* str, size_t len) nothrow @nogc;
const(char)* JS_ToCStringLen2(JSContext* ctx, size_t* plen, JSValueConst val,
                              bool cesu8) nothrow @nogc;
void JS_FreeCString(JSContext* ctx, const(char)* ptr) nothrow @nogc;

JSValue JS_NewObject(JSContext* ctx) nothrow @nogc;
JSValue JS_NewArray(JSContext* ctx) nothrow @nogc;
JSValue JS_GetPropertyStr(JSContext* ctx, JSValueConst thisObj,
                          const(char)* prop) nothrow @nogc;
JSValue JS_GetPropertyUint32(JSContext* ctx, JSValueConst thisObj,
                             uint idx) nothrow @nogc;
// QuickJS-NG property setters return a positive value on success and 0 or -1
// on failure (older QuickJS releases returned 0 on success). Both take
// ownership of `val` on every path.
int JS_SetPropertyStr(JSContext* ctx, JSValueConst thisObj, const(char)* prop,
                      JSValue val) nothrow @nogc;
int JS_SetPropertyUint32(JSContext* ctx, JSValueConst thisObj, uint idx,
                         JSValue val) nothrow @nogc;
bool JS_IsFunction(JSContext* ctx, JSValueConst val) nothrow @nogc;
bool JS_IsArray(JSValueConst val) nothrow @nogc;
bool JS_IsProxy(JSValueConst val) nothrow @nogc;

// static inline in quickjs.h
bool jsIsString(JSValueConst v) @nogc nothrow
{
    return v.tag == JS_TAG_STRING || v.tag == JS_TAG_STRING_ROPE;
}

JSValue JS_NewCFunction2(JSContext* ctx, JSCFunction func, const(char)* name,
                         int length, int cproto, int magic) nothrow @nogc;

JSValue JS_NewCFunctionData(JSContext* ctx, JSCFunctionData func, int length,
                            int magic, int dataLen, JSValue* data) nothrow @nogc;

alias JSReallocArrayBufferDataFunc = void* function(JSRuntime* rt, void* opaque,
                                                    void* ptr, size_t size)
    nothrow @nogc;
JSValue JS_NewArrayBuffer(JSContext* ctx, ubyte* buf, size_t len, size_t maxLen,
                          JSReallocArrayBufferDataFunc reallocFunc, void* opaque,
                          bool isShared) nothrow @nogc;
JSValue JS_NewArrayBufferCopy(JSContext* ctx, const(ubyte)* buf, size_t len) nothrow @nogc;
JSValue JS_ThrowOutOfMemory(JSContext* ctx) nothrow @nogc;
size_t JS_GetArrayBufferBytes(JSContext* ctx) nothrow @nogc;
ubyte* JS_GetArrayBuffer(JSContext* ctx, size_t* psize, JSValueConst obj) nothrow @nogc;
ubyte* JS_GetUint8Array(JSContext* ctx, size_t* psize, JSValueConst obj) nothrow @nogc;
JSValue JS_GetTypedArrayBuffer(JSContext* ctx, JSValueConst obj, size_t* pbyteOffset,
                               size_t* pbyteLength, size_t* pbytesPerElement) nothrow @nogc;
int JS_GetTypedArrayType(JSValueConst obj) nothrow @nogc;
bool JS_IsArrayBuffer(JSValueConst obj) nothrow @nogc;

void JS_SetHostPromiseRejectionTracker(JSRuntime* rt,
                                       JSHostPromiseRejectionTracker cb,
                                       void* opaque) nothrow @nogc;
bool JS_IsJobPending(JSRuntime* rt) nothrow @nogc;
int JS_EnqueueJob(JSContext* ctx, JSJobFunc jobFunc, int argc,
                  JSValueConst* argv) nothrow @nogc;
int JS_ExecutePendingJob(JSRuntime* rt, JSContext** pctx) nothrow @nogc;

// 64-bit integers. Timer ids are BigInt so the (generation, index) pair never
// rounds through a double.
JSValue JS_NewBigInt64(JSContext* ctx, long v) nothrow @nogc;
int JS_ToBigInt64(JSContext* ctx, long* pres, JSValueConst val) nothrow @nogc;

// JSMemoryUsage is a flat struct of int64 counters in the pinned header; the
// ABI probe checks its size so a mirror cannot drift silently.
struct JSMemoryUsage
{
    long malloc_size, malloc_limit, memory_used_size;
    long malloc_count;
    long memory_used_count;
    long atom_count, atom_size;
    long str_count, str_size;
    long obj_count, obj_size;
    long prop_count, prop_size;
    long shape_count, shape_size;
    long js_func_count, js_func_size, js_func_code_size;
    long js_func_pc2line_count, js_func_pc2line_size;
    long c_func_count, array_count;
    long fast_array_count, fast_array_elements;
    long binary_object_count, binary_object_size;
}
static assert(JSMemoryUsage.sizeof == 208);
void JS_ComputeMemoryUsage(JSRuntime* rt, JSMemoryUsage* s) nothrow @nogc;
JSValue JS_EvalFunction(JSContext* ctx, JSValue funObj) nothrow @nogc;
JSValue JS_ParseJSON(JSContext* ctx, const(char)* buf, size_t len,
                     const(char)* filename) nothrow @nogc;

// Modules. A normalized specifier is allocated with js_malloc() and freed by
// the engine with js_free(); every other name here is borrowed.
struct JSModuleDef;
alias JSModuleNormalizeFunc = extern(C) char* function(JSContext* ctx,
                                                       const(char)* base,
                                                       const(char)* name,
                                                       void* opaque) nothrow @nogc;
alias JSModuleNormalizeFunc2 = extern(C) char* function(JSContext* ctx,
                                                         const(char)* base,
                                                         const(char)* name,
                                                         JSValueConst attributes,
                                                         void* opaque) nothrow @nogc;
alias JSModuleLoaderFunc2 = extern(C) JSModuleDef* function(JSContext* ctx,
                                                            const(char)* name,
                                                            void* opaque,
                                                            JSValueConst attributes) nothrow @nogc;
alias JSModuleCheckAttrs = extern(C) int function(JSContext* ctx, void* opaque,
                                                 JSValueConst attributes) nothrow @nogc;
void JS_SetModuleLoaderFunc2(JSRuntime* rt, JSModuleNormalizeFunc normalize,
                             JSModuleLoaderFunc2 load, JSModuleCheckAttrs checkAttrs,
                             void* opaque) nothrow @nogc;
void JS_SetModuleNormalizeFunc2(JSRuntime* rt,
                                JSModuleNormalizeFunc2 normalize) nothrow @nogc;
JSValue JS_GetImportMeta(JSContext* ctx, JSModuleDef* m) nothrow @nogc;
void* js_malloc(JSContext* ctx, size_t size) nothrow @nogc;
void js_free(JSContext* ctx, void* ptr) nothrow @nogc;
