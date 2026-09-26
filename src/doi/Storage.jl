# SPDX-License-Identifier: MPL-2.0
# Publication state is separate from immutable scientific objects. Never store secrets here.
module DOIStorage

using JSON3, SHA, OrderedCollections

export PublicationError, atomic_write, atomic_json, read_json, canonical_json,
       with_publication_lock, file_sha256, private_dir, FileBody

struct PublicationError <: Exception
    status::Int
    code::String
    message::String
end
Base.showerror(io::IO, e::PublicationError) = print(io, e.message)

canonical(x::AbstractDict) = OrderedDict(String(k) => canonical(x[k]) for k in sort!(collect(keys(x)); by=string))
canonical(x::AbstractVector) = canonical.(x)
canonical(x) = x
canonical_json(x) = JSON3.write(canonical(x))
file_sha256(path::AbstractString) = open(io -> bytes2hex(sha256(io)), path)
read_json(path::AbstractString) = JSON3.read(read(path, String), Dict{String,Any})


# Lazy HTTP response body: open only while writing, close on success/disconnect,
# and use bounded memory even for large publication archives.
struct FileBody
    path::String
end
Base.length(body::FileBody) = filesize(body.path)
function Base.write(destination::IO, body::FileBody)
    open(body.path, "r") do source
        buffer = Vector{UInt8}(undef, 1024 * 1024)
        total = 0
        while !eof(source)
            count = readbytes!(source, buffer)
            count == 0 && break
            total += write(destination, view(buffer, 1:count))
        end
        return total
    end
end

function private_dir(path::AbstractString)
    islink(path) && throw(PublicationError(409, "unsafe_storage", "Publication storage must not be a symlink."))
    mkpath(path; mode=0o700)
    chmod(path, 0o700)
    return path
end

# Supported deployment targets are native Unix and WSL2. Kernel locks are released
# on process death: unlike age-based lockfiles they cannot expire during a slow upload.
# Do not silently substitute a process-local mutex on unsupported platforms.
function with_publication_lock(f::Function, directory::AbstractString)
    Sys.isunix() || throw(PublicationError(503, "unsupported_storage", "DOI publication requires a Unix filesystem with flock support (including WSL2)."))
    private_dir(directory)
    path = joinpath(directory, ".lock")
    islink(path) && throw(PublicationError(409, "unsafe_storage", "Publication lock must not be a symlink."))
    open(path, "a+") do io
        chmod(path, 0o600)
        acquired = ccall(:flock, Cint, (Cint, Cint), fd(io), 2 | 4) == 0 # LOCK_EX | LOCK_NB
        acquired || throw(PublicationError(409, "publication_busy", "Another publication operation is running. Refresh its status before retrying."))
        try
            return f()
        finally
            ccall(:flock, Cint, (Cint, Cint), fd(io), 8) # LOCK_UN
        end
    end
end

function atomic_write(path::AbstractString, content::AbstractString)
    private_dir(dirname(path))
    islink(path) && throw(PublicationError(409, "unsafe_storage", "Publication files must not be symlinks."))
    tmp, io = mktemp(dirname(path); cleanup=false)
    try
        chmod(tmp, 0o600)
        write(io, content)
        flush(io)
        if Sys.isunix()
            rc = ccall(:fsync, Cint, (Cint,), fd(io))
            rc == 0 || error("Could not synchronise publication state")
        end
        close(io)
        # rename, not rm + mv: readers must see either complete version, never a gap.
        Base.Filesystem.rename(tmp, path)
        if Sys.isunix()
            dirfd = ccall(:open, Cint, (Cstring, Cint), dirname(path), 0)
            dirfd >= 0 || error("Could not open publication state directory")
            try
                ccall(:fsync, Cint, (Cint,), dirfd) == 0 || error("Could not synchronise publication state directory")
            finally
                ccall(:close, Cint, (Cint,), dirfd)
            end
        end
    finally
        isopen(io) && close(io)
        isfile(tmp) && rm(tmp)
    end
    return path
end
atomic_json(path::AbstractString, value) = atomic_write(path, canonical_json(value) * "\n")

end # module DOIStorage
