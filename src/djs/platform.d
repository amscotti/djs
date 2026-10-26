module djs.platform;

// Platform compatibility layer.
//
// The pinned druntime does not declare a handful of POSIX functions/constants
// for every target, and some constants differ between Linux and Darwin.
// Call sites import this module instead of the raw C headers, so the
// differences live in one auditable place.
//
// Values are taken from the platform SDK headers:
//   O_CLOEXEC   = 0x01000000  (MacOSX.sdk/usr/include/sys/fcntl.h)
//   O_NOFOLLOW  = 0x00000100  (MacOSX.sdk/usr/include/sys/fcntl.h)
//   CLOCK_MONOTONIC = 6       (MacOSX.sdk/usr/include/_time.h; Linux uses 1)
//
// Everything here is @nogc nothrow; the module must stay usable from the
// C boundary.

version (linux)
{
    public import core.sys.posix.fcntl : O_CLOEXEC, O_NOFOLLOW;
    public import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC;
    public import core.sys.posix.unistd : fdatasync;

    // Linux druntime declares the mode-taking calls with a uint mode.
    alias Mode = uint;

    private import core.sys.posix.unistd : environ;
    char** environPtr() @trusted @nogc nothrow
    {
        return cast(char**) environ;
    }
}
else version (OSX)
{
    enum int O_CLOEXEC = 0x01000000;
    enum int O_NOFOLLOW = 0x00000100;

    enum int CLOCK_MONOTONIC = 6;
    private import core.sys.posix.time : timespec;
    extern(C) int clock_gettime(int clockid, timespec* tp) nothrow @nogc;

    // libSystem exports fdatasync, but the macOS SDK does not prototype it
    // and druntime does not declare it for Darwin.
    extern(C) int fdatasync(int fd) nothrow @nogc;

    // Darwin druntime declares mkdir/chmod/fchmod/umask with a ushort mode.
    alias Mode = ushort;

    // Darwin's unistd exposes `environ` as a property returning const(char**).
    private import core.sys.posix.unistd : environ;
    char** environPtr() @trusted @nogc nothrow
    {
        return cast(char**) environ();
    }
}
else
{
    enum int O_CLOEXEC = 0;
    enum int O_NOFOLLOW = 0;
    enum int CLOCK_MONOTONIC = 0;
    alias Mode = uint;

    char** environPtr() @safe @nogc nothrow
    {
        return null;
    }
}
