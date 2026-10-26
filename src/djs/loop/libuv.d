module djs.loop.libuv;

import core.sys.posix.netdb : addrinfo;
import core.sys.posix.sys.socket : sockaddr;

// Opaque libuv declarations. libuv deliberately exposes size and accessor
// functions so hosts do not mirror its structs; a truncated mirror of
// uv_timer_t (152 bytes) or uv_fs_t (440 bytes) is a heap overflow. All
// allocation below goes through uv_loop_size/uv_handle_size/uv_req_size.
extern(C):

struct uv_loop_t;
struct uv_handle_t;
struct uv_req_t;
struct uv_timer_t;
struct uv_prepare_t;
struct uv_idle_t;
struct uv_work_t;
struct uv_fs_t;
struct uv_poll_t;
struct uv_fs_event_t;
struct uv_getaddrinfo_t;
struct uv_getnameinfo_t;
struct uv_signal_t;

alias uv_close_cb = extern(C) void function(uv_handle_t* handle) nothrow @nogc;
alias uv_timer_cb = extern(C) void function(uv_timer_t* handle) nothrow @nogc;
alias uv_signal_cb = extern(C) void function(uv_signal_t* handle, int signum) nothrow @nogc;
alias uv_prepare_cb = extern(C) void function(uv_prepare_t* handle) nothrow @nogc;
alias uv_idle_cb = extern(C) void function(uv_idle_t* handle) nothrow @nogc;
alias uv_work_cb = extern(C) void function(uv_work_t* req) nothrow @nogc;
alias uv_poll_cb = extern(C) void function(uv_poll_t* handle, int status, int events) nothrow @nogc;

// fs events: libuv uses inotify on Linux and FSEvents (directories) or
// kqueue (files) on macOS. `filename` is relative to the watched path and
// may be null; `events` is a mask of UV_RENAME/UV_CHANGE.
alias uv_fs_event_cb = extern(C) void function(uv_fs_event_t* handle,
    const(char)* filename, int events, int status) nothrow @nogc;

enum int UV_RENAME = 1;
enum int UV_CHANGE = 2;
enum int UV_FS_EVENT_WATCH_ENTRY = 1;
enum int UV_FS_EVENT_STAT = 2;
enum int UV_FS_EVENT_RECURSIVE = 4;
alias uv_getaddrinfo_cb = extern(C) void function(uv_getaddrinfo_t* req, int status, addrinfo* res) nothrow @nogc;
alias uv_getnameinfo_cb = extern(C) void function(uv_getnameinfo_t* req, int status,
                                                const(char)* hostname,
                                                const(char)* service) nothrow @nogc;
alias uv_after_work_cb = extern(C) void function(uv_work_t* req, int status) nothrow @nogc;

// uv_handle_type values from uv.h (the order is ABI, not a guess).
enum int UV_UNKNOWN_HANDLE = 0;
enum int UV_ASYNC = 1;
enum int UV_CHECK = 2;
enum int UV_FS_EVENT = 3;
enum int UV_FS_POLL = 4;
enum int UV_HANDLE = 5;
enum int UV_IDLE = 6;
enum int UV_NAMED_PIPE = 7;
enum int UV_POLL = 8;
enum int UV_PREPARE = 9;
enum int UV_PROCESS = 10;
enum int UV_STREAM = 11;
enum int UV_TCP = 12;
enum int UV_TIMER = 13;
enum int UV_TTY = 14;
enum int UV_UDP = 15;
enum int UV_SIGNAL = 16;

// uv_req_type values from uv.h.
enum int UV_UNKNOWN_REQ = 0;
enum int UV_REQ = 1;
enum int UV_CONNECT = 2;
enum int UV_WRITE = 3;
enum int UV_SHUTDOWN = 4;
enum int UV_UDP_SEND = 5;
enum int UV_FS = 6;
enum int UV_WORK = 7;
enum int UV_GETADDRINFO = 8;
enum int UV_GETNAMEINFO = 9;
enum int UV_RANDOM = 10;

enum int UV_READABLE = 1;
enum int UV_WRITABLE = 2;
enum int UV_DISCONNECT = 4;

enum int UV_RUN_DEFAULT = 0;
enum int UV_RUN_ONCE = 1;
enum int UV_RUN_NOWAIT = 2;

size_t uv_loop_size() nothrow @nogc;
int uv_loop_init(uv_loop_t* loop) nothrow @nogc;
int uv_loop_close(uv_loop_t* loop) nothrow @nogc;
int uv_loop_alive(const uv_loop_t* loop) nothrow @nogc;
int uv_run(uv_loop_t* loop, int mode) nothrow @nogc;
void uv_stop(uv_loop_t* loop) nothrow @nogc;

size_t uv_handle_size(int type) nothrow @nogc;
size_t uv_req_size(int type) nothrow @nogc;
void* uv_handle_get_data(const uv_handle_t* handle) nothrow @nogc;
void uv_handle_set_data(uv_handle_t* handle, void* data) nothrow @nogc;
void* uv_req_get_data(const uv_req_t* req) nothrow @nogc;
void uv_req_set_data(uv_req_t* req, void* data) nothrow @nogc;

void uv_ref(uv_handle_t* handle) nothrow @nogc;
void uv_unref(uv_handle_t* handle) nothrow @nogc;
int uv_has_ref(const uv_handle_t* handle) nothrow @nogc;
int uv_is_closing(const uv_handle_t* handle) nothrow @nogc;
void uv_close(uv_handle_t* handle, uv_close_cb cb) nothrow @nogc;

int uv_timer_init(uv_loop_t* loop, uv_timer_t* handle) nothrow @nogc;
int uv_timer_start(uv_timer_t* handle, uv_timer_cb cb, ulong timeout,
                   ulong repeat) nothrow @nogc;
int uv_timer_stop(uv_timer_t* handle) nothrow @nogc;
int uv_timer_again(uv_timer_t* handle) nothrow @nogc;
void uv_timer_set_repeat(uv_timer_t* handle, ulong repeat) nothrow @nogc;
ulong uv_timer_get_repeat(const uv_timer_t* handle) nothrow @nogc;

int uv_signal_init(uv_loop_t* loop, uv_signal_t* handle) nothrow @nogc;
int uv_signal_start(uv_signal_t* handle, uv_signal_cb cb, int signum) nothrow @nogc;
int uv_signal_stop(uv_signal_t* handle) nothrow @nogc;

int uv_prepare_init(uv_loop_t* loop, uv_prepare_t* prepare) nothrow @nogc;
int uv_prepare_start(uv_prepare_t* prepare, uv_prepare_cb cb) nothrow @nogc;
int uv_prepare_stop(uv_prepare_t* prepare) nothrow @nogc;

int uv_idle_init(uv_loop_t* loop, uv_idle_t* idle) nothrow @nogc;
int uv_idle_start(uv_idle_t* idle, uv_idle_cb cb) nothrow @nogc;
int uv_idle_stop(uv_idle_t* idle) nothrow @nogc;

int uv_getaddrinfo(uv_loop_t* loop, uv_getaddrinfo_t* req, uv_getaddrinfo_cb cb,
                   const(char)* node, const(char)* service, const(addrinfo)* hints) nothrow @nogc;
void uv_freeaddrinfo(addrinfo* ai) nothrow @nogc;

int uv_getnameinfo(uv_loop_t* loop, uv_getnameinfo_t* req, uv_getnameinfo_cb cb,
                   const(sockaddr)* addr, int flags) nothrow @nogc;

int uv_fs_event_init(uv_loop_t* loop, uv_fs_event_t* handle) nothrow @nogc;
int uv_fs_event_start(uv_fs_event_t* handle, uv_fs_event_cb cb,
                      const(char)* path, int flags) nothrow @nogc;
int uv_fs_event_stop(uv_fs_event_t* handle) nothrow @nogc;

// uv_cpu_info_t: char* model; int speed; five uint64 times. libuv allocates
// the array and the model strings; uv_free_cpu_info releases them.
struct uv_cpu_times_t
{
    ulong user;
    ulong nice;
    ulong sys;
    ulong idle;
    ulong irq;
}
struct uv_cpu_info_t
{
    char* model;
    int speed;
    uv_cpu_times_t cpu_times;
}
int uv_cpu_info(uv_cpu_info_t** cpu_infos, int* count) nothrow @nogc;
void uv_free_cpu_info(uv_cpu_info_t* cpu_infos, int count) nothrow @nogc;

int uv_poll_init_socket(uv_loop_t* loop, uv_poll_t* handle, int socket) nothrow @nogc;
int uv_poll_start(uv_poll_t* handle, int events, uv_poll_cb cb) nothrow @nogc;
int uv_poll_stop(uv_poll_t* handle) nothrow @nogc;

int uv_queue_work(uv_loop_t* loop, uv_work_t* req, uv_work_cb workCb,
                  uv_after_work_cb afterCb) nothrow @nogc;
int uv_cancel(uv_req_t* req) nothrow @nogc;

const(char)* uv_strerror(int err) nothrow @nogc;
const(char)* uv_err_name(int err) nothrow @nogc;
int uv_translate_sys_error(int sysErrno) nothrow @nogc;
int uv_resident_set_memory(size_t* rss) nothrow @nogc;
ulong uv_hrtime() nothrow @nogc;
ulong uv_now(const uv_loop_t* loop) nothrow @nogc;
const(char)* uv_version_string() nothrow @nogc;
