# SPDX-License-Identifier: MPL-2.0
# Linux-only, single-threaded supervision of trusted probe subprocesses.
#
# A subreaper adopts orphaned descendants even if they call setsid/double-fork.
# Restore the previous process-wide setting; refuse pre-existing child contexts.
# This is lifecycle management, not a sandbox for adversarial executables.
module FormatDescendants

export SupervisionError, ProcessLookupError, supervise

const PR_SET_CHILD_SUBREAPER = 36
const PR_GET_CHILD_SUBREAPER = 37
const SIGSTOP = 19
const SIGKILL = 9
const ENOENT = 2
const ESRCH = 3
const ECHILD = 10
const WNOHANG = 1

struct SupervisionError <: Exception
    msg::String
end
Base.showerror(io::IO, e::SupervisionError) = print(io, "SupervisionError: ", e.msg)

# Stands in for Python's ProcessLookupError (errno ESRCH).
struct ProcessLookupError <: Exception end
Base.showerror(io::IO, ::ProcessLookupError) = print(io, "ProcessLookupError")

# Filesystem seams. Tests replace these to simulate a missing procfs.
const LISTDIR = Ref{Function}(readdir)
const READTEXT = Ref{Function}(path -> read(path, String))
const CHILDREN = Ref{Function}(pid -> _children(pid))

is_enoent(e) = (e isa Base.IOError && e.code == Base.UV_ENOENT) ||
               (e isa SystemError && e.errnum == ENOENT)

children(pid) = CHILDREN[](pid)

function _children(pid::Integer)
    result = Set{Int}()
    local tasks
    try
        tasks = LISTDIR[]("/proc/$pid/task")
    catch error
        is_enoent(error) || rethrow()
        pid == getpid() && throw(SupervisionError("procfs child enumeration unavailable"))
        return result
    end
    for task in tasks
        try
            for value in split(READTEXT[]("/proc/$pid/task/$task/children"))
                push!(result, parse(Int, value))
            end
        catch error
            is_enoent(error) || rethrow()
            if pid == getpid() && task == string(pid)
                throw(SupervisionError("procfs children interface unavailable"))
            end
            # A different process/thread exited during enumeration.
        end
    end
    return result
end

# Returns true when the signal was delivered, false for ESRCH.
function send_signal(pid::Integer, signum::Integer)
    ccall(:kill, Cint, (Cint, Cint), pid, signum) == 0 && return true
    errno = Libc.errno()
    errno == ESRCH && return false
    throw(SystemError("kill", errno))
end

function kill_tree(pid::Integer)
    pending, stopped = Int[pid], Int[]
    while !isempty(pending)
        current = pop!(pending)
        # The process may exit after its parent list was read; it then has no
        # live descendants to freeze.
        send_signal(current, SIGSTOP) || continue
        push!(stopped, current)
        append!(pending, children(current))
    end
    for current in reverse(stopped)
        # A frozen process can still disappear if it was reaped concurrently.
        send_signal(current, SIGKILL)
    end
end

# waitpid(WNOHANG); ECHILD means it was already reaped elsewhere.
function reap_nowait(pid::Integer)
    status = Ref{Cint}(0)
    result = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, WNOHANG)
    if result == -1 && Libc.errno() != ECHILD
        throw(SystemError("waitpid", Libc.errno()))
    end
    return nothing
end

now_s() = time_ns() * 1e-9

function drain()
    deadline = now_s() + 0.5
    while now_s() < deadline
        found = children(getpid())
        isempty(found) && return
        for pid in sort!(collect(found))
            kill_tree(pid)
            reap_nowait(pid)
        end
        remaining = deadline - now_s()
        # Bounded cleanup; also reap newly adopted orphans.
        remaining > 0 && sleep(min(0.005, remaining))
    end

    # A final census lets a child that exited at the deadline be reaped,
    # and catches anything newly adopted by the subreaper during cleanup.
    found = children(getpid())
    isempty(found) && return
    for pid in sort!(collect(found))
        kill_tree(pid)
        reap_nowait(pid)
    end
    isempty(children(getpid())) ||
        throw(SupervisionError("descendants did not exit within cleanup budget"))
    return
end

function set_subreaper(value::Integer)
    ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong),
          PR_SET_CHILD_SUBREAPER, value, 0, 0, 0) == 0 ||
        throw(SupervisionError("cannot set subreaper state"))
    return nothing
end

"""
    supervise(f)

Run `f()` with this process as a child subreaper. Afterwards every adopted
descendant is stopped, killed and reaped, and the previous setting restored.
"""
function supervise(f)
    if !Sys.islinux() || Threads.nthreads() != 1
        throw(SupervisionError("probe requires single-threaded Linux supervision"))
    end
    previous = Ref{Cint}(0)
    ccall(:prctl, Cint, (Cint, Ptr{Cint}, Culong, Culong, Culong),
          PR_GET_CHILD_SUBREAPER, previous, 0, 0, 0) == 0 ||
        throw(SupervisionError("cannot inspect subreaper state"))
    isempty(children(getpid())) ||
        throw(SupervisionError("probe requires no pre-existing child processes"))
    set_subreaper(1)
    try
        return f()
    finally
        try
            drain()
        finally
            set_subreaper(previous[])
        end
    end
end

end # module
