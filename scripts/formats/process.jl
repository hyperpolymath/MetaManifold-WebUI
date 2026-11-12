# SPDX-License-Identifier: MPL-2.0
# Bounded Linux IO for a deliberately closed set of format-probe commands.
#
# Installed tools are trusted executables, not sandboxed plugins. A trusted PATH
# provides their location; no program paths or argument strings come from a CLI.
# Child diagnostics can contain secrets and are not printed by the probe CLIs.
isdefined(Main, :FormatDescendants) || Base.include(Main, joinpath(@__DIR__, "descendants.jl"))

module FormatProcess

using Main.FormatDescendants: SupervisionError, ProcessLookupError, supervise
import Main.FormatDescendants

export ToolError, ValueError, Result, run_probe, pyname, CliOption, parse_cli

const TIMEOUT = "tool exceeded its time budget"
const COMMANDS = Dict{String,Vector{String}}(
    "ijson-canon" => ["ijson-jcs", "canon"],
    "kyq-canon" => ["kyq-json-adapter", "canon"],
    "git-head" => ["git", "rev-parse", "HEAD"],
    "git-status" => ["git", "status", "--porcelain", "--untracked-files=all"],
    "just-version" => ["just", "--version"],
    "just-build" => ["just", "build"],
    "just-wasm" => ["just", "wasm"],
    "just-test" => ["just", "test"],
)

const SIGKILL = 9
const EAGAIN = 11
const EINTR = 4
const EPIPE = 32
const O_CLOEXEC = 0o2000000
const O_NONBLOCK = 0o4000
const F_GETFL = 3
const F_SETFL = 4
const POLLIN = 0x0001
const POLLOUT = 0x0004
const CHUNK = 16384

"Infrastructure failure; distinct from a tool rejecting a document."
struct ToolError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ToolError) = print(io, "ToolError: ", e.msg)

"Stands in for Python's ValueError family; `name` is the Python class name reported."
struct ValueError <: Exception
    msg::String
    name::String
end
ValueError(msg::AbstractString) = ValueError(String(msg), "ValueError")
Base.showerror(io::IO, e::ValueError) = print(io, e.name, ": ", e.msg)

struct Result
    code::Int
    stdout::Vector{UInt8}
    stderr::Vector{UInt8}
end

struct WaitTimeout <: Exception end

# The Python exception class name that the original CLIs print in diagnostics.
function pyname(e)
    e isa ToolError && return "ToolError"
    e isa ValueError && return e.name
    e isa Base.IOError && return e.code == Base.UV_ENOENT ? "FileNotFoundError" : "OSError"
    e isa SystemError && return e.errnum == 2 ? "FileNotFoundError" : "OSError"
    e isa ProcessLookupError && return "ProcessLookupError"
    e isa KeyError && return "KeyError"
    return string(nameof(typeof(e)))
end

# ---- command resolution -------------------------------------------------

# Same lookup rules as Python's shutil.which on POSIX.
function which(name::AbstractString)
    path = get(ENV, "PATH", nothing)
    path === nothing && (path = "/bin:/usr/bin")
    isempty(path) && return nothing
    seen = Set{String}()
    for dir in split(path, ':'; keepempty=true)
        dir in seen && continue
        push!(seen, dir)
        candidate = joinpath(dir, name)
        if ispath(candidate) && Base.Filesystem.isexecutable(candidate) && !isdir(candidate)
            return candidate
        end
    end
    return nothing
end

function command(name)
    if !(name isa AbstractString) || !haskey(COMMANDS, name)
        throw(ToolError("unknown probe operation"))
    end
    # Only select complete, literal commands. Neither program paths nor argv
    # strings from a CLI are passed through to process creation.
    argv = COMMANDS[name]
    location = which(argv[1])
    location === nothing && throw(ToolError("tool not found on trusted PATH"))
    basename(realpath(location)) == argv[1] ||
        throw(ToolError("tool resolves to an unrelated executable"))
    return argv
end

# ---- raw descriptor helpers ---------------------------------------------

close_fd(fd::Integer) = fd >= 0 && ccall(:close, Cint, (Cint,), fd)

function make_pipe()
    fds = Vector{Cint}(undef, 2)
    ccall(:pipe2, Cint, (Ptr{Cint}, Cint), fds, O_CLOEXEC) == 0 ||
        throw(SystemError("pipe2", Libc.errno()))
    return Int(fds[1]), Int(fds[2])
end

function set_nonblocking(fd::Integer)
    flags = ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, F_GETFL, 0)
    flags < 0 && throw(SystemError("fcntl", Libc.errno()))
    ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, F_SETFL, flags | O_NONBLOCK) < 0 &&
        throw(SystemError("fcntl", Libc.errno()))
    return nothing
end

# ---- child abstraction (the tests substitute a mock for the cleanup cases) --

mutable struct Child
    proc::Base.Process
    pid::Int
    stdin_fd::Int
    stdout_fd::Int
    stderr_fd::Int
end

child_pid(c::Child) = c.pid

function exit_code(c::Child)
    p = c.proc
    return p.termsignal != 0 ? -Int(p.termsignal) : Int(p.exitcode)
end

# Non-blocking exit check; the exit is only observed while libuv's loop runs.
function child_poll(c::Child)
    Base.process_exited(c.proc) || sleep(0.0005)
    return Base.process_exited(c.proc) ? exit_code(c) : nothing
end

function child_kill(c::Child)
    child_poll(c) === nothing || return nothing
    if ccall(:kill, Cint, (Cint, Cint), c.pid, SIGKILL) != 0
        Libc.errno() == 3 || throw(SystemError("kill", Libc.errno()))
    end
    return nothing
end

function child_wait(c::Child, timeout::Real)
    ok = timedwait(() -> Base.process_exited(c.proc), Float64(timeout); pollint=0.002)
    ok === :ok || throw(WaitTimeout())
    return exit_code(c)
end

function close_streams(c::Child)
    for field in (:stdin_fd, :stdout_fd, :stderr_fd)
        fd = getfield(c, field)
        if fd >= 0
            setfield!(c, field, -1)
            close_fd(fd)
        end
    end
    return nothing
end

function spawn_child(argv::Vector{String}, cwd)
    in_r, in_w = make_pipe()
    local out_r, out_w, err_r, err_w
    out_r = out_w = err_r = err_w = -1
    local proc
    try
        out_r, out_w = make_pipe()
        err_r, err_w = make_pipe()
        # detach => the child calls setsid(): its own session and process group.
        cmd = Cmd(Cmd(argv); detach=true, dir=cwd === nothing ? "" : String(cwd))
        proc = Base.run(pipeline(cmd; stdin=RawFD(in_r), stdout=RawFD(out_w),
                                 stderr=RawFD(err_w)); wait=false)
    catch
        for fd in (in_r, in_w, out_r, out_w, err_r, err_w)
            close_fd(fd)
        end
        rethrow()
    end
    close_fd(in_r); close_fd(out_w); close_fd(err_w)
    set_nonblocking(in_w); set_nonblocking(out_r); set_nonblocking(err_r)
    return Child(proc, Int(getpid(proc)), in_w, out_r, err_r)
end

# Seam so a test can prove nothing is launched.
const SPAWN = Ref{Function}(spawn_child)

# ---- IO pump -------------------------------------------------------------

struct PollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end

mutable struct Pump
    child::Child
    data::Vector{UInt8}
    limit::Int
    offset::Int
    total::Int
    out::Vector{UInt8}
    err::Vector{UInt8}
end
Pump(child, data, limit) = Pump(child, data, limit, 0, 0, UInt8[], UInt8[])

now_s() = time_ns() * 1e-9

function remaining(deadline)
    left = deadline - now_s()
    left <= 0 && throw(ToolError(TIMEOUT))
    return left
end

function close_field!(c::Child, field::Symbol)
    fd = getfield(c, field)
    setfield!(c, field, -1)
    close_fd(fd)
end

function write_input!(p::Pump)
    c = p.child
    n = min(CHUNK, length(p.data) - p.offset)
    data = p.data
    written = GC.@preserve data ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                                        c.stdin_fd, pointer(data, p.offset + 1), n)
    if written < 0
        errno = Libc.errno()
        if errno == EPIPE
            p.offset = length(p.data)
        elseif errno == EAGAIN || errno == EINTR
            return
        else
            throw(SystemError("write", errno))
        end
    else
        p.offset += written
    end
    p.offset == length(p.data) && close_field!(c, :stdin_fd)
    return
end

function read_output!(p::Pump, field::Symbol, sink::Vector{UInt8})
    c = p.child
    buffer = Vector{UInt8}(undef, CHUNK)
    got = GC.@preserve buffer ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                                    getfield(c, field), pointer(buffer), CHUNK)
    if got < 0
        errno = Libc.errno()
        (errno == EAGAIN || errno == EINTR) && return
        throw(SystemError("read", errno))
    elseif got == 0
        close_field!(c, field)
        return
    end
    p.total += got
    p.total > p.limit && throw(ToolError("tool exceeded its output budget"))
    append!(sink, view(buffer, 1:got))
    return
end

function collect_output(p::Pump, deadline)
    c = p.child
    isempty(p.data) && close_field!(c, :stdin_fd)
    while c.stdout_fd >= 0 || c.stderr_fd >= 0 || c.stdin_fd >= 0
        left = remaining(deadline)
        polls = PollFD[]
        fields = Symbol[]
        for (field, event) in ((:stdout_fd, POLLIN), (:stderr_fd, POLLIN), (:stdin_fd, POLLOUT))
            fd = getfield(c, field)
            fd >= 0 || continue
            push!(polls, PollFD(fd, event, 0))
            push!(fields, field)
        end
        millis = clamp(ceil(Int, left * 1000), 1, typemax(Int32))
        ready = ccall(:poll, Cint, (Ptr{PollFD}, Culong, Cint), polls, length(polls), millis)
        if ready < 0
            errno = Libc.errno()
            errno == EINTR && continue
            throw(SystemError("poll", errno))
        end
        for (entry, field) in zip(polls, fields)
            entry.revents == 0 && continue
            if field === :stdin_fd
                write_input!(p)
            elseif field === :stdout_fd
                read_output!(p, field, p.out)
            else
                read_output!(p, field, p.err)
            end
        end
    end
    code = try
        child_wait(c, remaining(deadline))
    catch error
        error isa WaitTimeout ? throw(ToolError(TIMEOUT)) : rethrow()
    end
    return Result(code, copy(p.out), copy(p.err))
end

# ---- cleanup ------------------------------------------------------------

function killpg_real(pid::Integer)
    ccall(:killpg, Cint, (Cint, Cint), pid, SIGKILL) == 0 && return nothing
    errno = Libc.errno()
    errno == 3 && throw(ProcessLookupError())
    throw(SystemError("killpg", errno))
end

# Fast group cleanup; supervise also adopts/kills detached descendants.
function cleanup(child; killpg=killpg_real)
    try
        try
            killpg(child_pid(child))
        catch error
            error isa ProcessLookupError || rethrow()
            # A tool can leave its session; do not mistake a missing process
            # group for a stopped direct child.
            if child_poll(child) === nothing
                try
                    child_kill(child)
                catch error2
                    error2 isa ProcessLookupError || rethrow()
                    # The child may exit between poll and kill; verify that
                    # race instead of silently discarding an unexpected live PID.
                    if child_poll(child) === nothing
                        throw(ToolError(
                            "tool escaped its process group and could not be terminated"))
                    end
                end
            end
        end
        try
            child_wait(child, 0.5)
        catch error
            error isa WaitTimeout || rethrow()
            throw(ToolError("tool did not exit within cleanup budget"))
        end
    finally
        close_streams(child)
    end
    return nothing
end

# ---- public entry point -------------------------------------------------

function run_probe(operation, data::AbstractVector{UInt8}=UInt8[]; cwd=nothing,
                   timeout::Real=5.0, limit::Integer=131072)
    if !isfinite(timeout) || timeout <= 0 || limit <= 0 || length(data) > limit
        throw(ToolError("invalid process budget or oversized test input"))
    end
    bytes = Vector{UInt8}(data)
    try
        return supervise() do
            child = SPAWN[](command(operation), cwd)
            try
                collect_output(Pump(child, bytes, Int(limit)), now_s() + timeout)
            finally
                cleanup(child)
            end
        end
    catch error
        if error isa SystemError || error isa Base.IOError || error isa SupervisionError ||
           error isa ProcessLookupError
            throw(ToolError("tool startup or descendant supervision failed"))
        end
        rethrow()
    end
end

# ---- minimal argparse stand-in -------------------------------------------

"One `--name VALUE` option. `convert` maps the string or throws; `choices` may be empty."
struct CliOption
    name::String
    metavar::String
    default::Any
    required::Bool
    convert::Function
    choices::Vector{String}
end
CliOption(name, metavar; default=nothing, required=false, convert=identity, choices=String[]) =
    CliOption(name, metavar, default, required, convert, choices)

function cli_usage(prog, options)
    parts = String["[-h]"]
    for o in options
        shown = isempty(o.choices) ? o.metavar : "{" * join(o.choices, ",") * "}"
        text = "--$(o.name) $shown"
        push!(parts, o.required ? text : "[" * text * "]")
    end
    return "usage: $prog " * join(parts, " ")
end

function cli_fail(prog, options, message)
    println(stderr, cli_usage(prog, options))
    println(stderr, "$prog: error: $message")
    exit(2)
end

"""
    parse_cli(prog, description, argv, options) -> Dict{String,Any}

Supports `--name value`, `--name=value`, unique long-option prefixes and `-h`.
Exits with status 2 on a usage error, like argparse.
"""
function parse_cli(prog, description, argv, options::Vector{CliOption})
    values = Dict{String,Any}(o.name => o.default for o in options)
    given = Set{String}()
    unrecognized = String[]
    index = 1
    while index <= length(argv)
        arg = String(argv[index])
        index += 1
        if arg == "-h" || arg == "--help"
            println(cli_usage(prog, options))
            println()
            println(description)
            exit(0)
        end
        if startswith(arg, "--") && length(arg) > 2
            key, eq, inline = partition(arg[3:end], '=')
            hits = [o for o in options if o.name == key]
            if isempty(hits)
                hits = [o for o in options if startswith(o.name, key)]
            end
            if length(hits) > 1
                cli_fail(prog, options, "ambiguous option: --$key could match " *
                         join(["--" * o.name for o in hits], ", "))
            elseif isempty(hits)
                push!(unrecognized, arg)
                continue
            end
            option = hits[1]
            if eq
                value = inline
            else
                if index > length(argv) ||
                   (startswith(argv[index], "-") && !occursin(r"^-(\d+\.?\d*|\.\d+)$", argv[index]))
                    cli_fail(prog, options, "argument --$(option.name): expected one argument")
                end
                value = String(argv[index])
                index += 1
            end
            if !isempty(option.choices) && !(value in option.choices)
                cli_fail(prog, options, "argument --$(option.name): invalid choice: '$value' " *
                         "(choose from " * join(["'$c'" for c in option.choices], ", ") * ")")
            end
            converted = try
                option.convert(value)
            catch
                cli_fail(prog, options, "argument --$(option.name): invalid value: '$value'")
            end
            values[option.name] = converted
            push!(given, option.name)
        else
            push!(unrecognized, arg)
        end
    end
    missing_required = ["--" * o.name for o in options if o.required && !(o.name in given)]
    isempty(missing_required) ||
        cli_fail(prog, options, "the following arguments are required: " * join(missing_required, ", "))
    isempty(unrecognized) ||
        cli_fail(prog, options, "unrecognized arguments: " * join(unrecognized, " "))
    return values
end

function partition(text, separator)
    i = findfirst(separator, text)
    i === nothing && return text, false, ""
    return text[1:prevind(text, i)], true, text[nextind(text, i):end]
end

end # module
