#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Synthetic SSH/SCP fault injection. The fake executables below never open a
# socket and refuse staging paths outside this process's temporary directory.
using Test, JSON3, MetaManifold
const RE = MetaManifold.RemoteExec

root = mktempdir(; cleanup=true)
bin = joinpath(root, "bin"); mkdir(bin)
remote_root = joinpath(root, "remote"); mkdir(remote_root)
log_path = joinpath(root, "commands.log")
write(joinpath(bin, "ssh"), """#!/usr/bin/env bash
set -eu
printf 'ssh %s\\n' "\$*" >> "\$FAULT_LOG"
cmd="\${@: -1}"
case "\$cmd" in
  'mkdir -p '*) read -r -a words <<< "\$cmd"; mkdir -p "\${words[@]:2}" ;;
  'find '*) exit 0 ;;
  'wc -c '*) read -r -a words <<< "\$cmd"; for p in "\${words[@]:2}"; do p=\${p//\\'/}; stat -c '%s %n' "\$p"; done ;;
  'rm -rf '*) read -r -a words <<< "\$cmd"; p="\${words[2]}"; [[ "\$p" == "\$FAULT_REMOTE/"* ]]; rm -rf -- "\$p"; printf 'CLEANED %s\\n' "\$p" >> "\$FAULT_LOG" ;;
  'test -f '*) read -r -a words <<< "\$cmd"; test -f "\${words[2]}" ;;
  *'printf synthetic-output > '*) if [[ "\${FAULT_MODE:-success}" == remote-fail ]]; then exit 23; fi; outfile=\${cmd##*> }; printf synthetic-output > "\$outfile" ;;
  *) for a in "\$@"; do [[ "\$a" == exit ]] && exit 0; done; echo 'unrecognised synthetic ssh command' >&2; exit 90 ;;
esac
""")
write(joinpath(bin, "scp"), """#!/usr/bin/env bash
set -eu
printf 'scp %s\\n' "\$*" >> "\$FAULT_LOG"
src="\${@: -2:1}"; dst="\${@: -1}"; src=\${src#synthetic.invalid:}; dst=\${dst#synthetic.invalid:}
[[ "\$src" == "\$FAULT_ROOT/"* || "\$dst" == "\$FAULT_ROOT/"* ]]
if [[ "\$dst" == "\$FAULT_REMOTE/"* ]]; then
  if [[ "\${FAULT_MODE:-success}" == upload-truncate ]]; then printf x > "\$dst"; else cp -- "\$src" "\$dst"; fi
else
  if [[ "\${FAULT_MODE:-success}" == download-truncate ]]; then printf x > "\$dst"; else cp -- "\$src" "\$dst"; fi
fi
""")
chmod(joinpath(bin, "ssh"), 0o755); chmod(joinpath(bin, "scp"), 0o755)
old_path = get(ENV, "PATH", ""); old_mode = get(ENV, "FAULT_MODE", nothing)
ENV["PATH"] = bin * ":" * old_path
ENV["FAULT_ROOT"] = root; ENV["FAULT_REMOTE"] = remote_root; ENV["FAULT_LOG"] = log_path
results = Any[]
try
    for mode in ("success", "upload-truncate", "remote-fail", "download-truncate")
        ENV["FAULT_MODE"] = mode
        case = joinpath(root, mode); mkdir(case)
        case_log = joinpath(case, "commands.log"); ENV["FAULT_LOG"] = case_log
        input = joinpath(case, "input.bin"); write(input, "synthetic-input")
        output = joinpath(case, "output.bin")
        target = (; host="synthetic.invalid", base=remote_root, identity_file=nothing, threads=1)
        err = nothing
        try
            RE.run_remote(_ -> nothing, target, dir -> "printf synthetic-output > $dir/output.bin";
                inputs=Pair{String,String}[input => "input.bin"],
                outputs=Pair{String,String}["output.bin" => output],
                log_path=joinpath(case, "stage.log"), stage="synthetic")
        catch e
            err = e
        end
        cleaned = isfile(case_log) && occursin("CLEANED $remote_root/synthetic_", read(case_log, String))
        # This records an observed limitation rather than asserting a desired
        # behaviour that the shared implementation does not provide.
        outcome = Dict("mode" => mode, "error" => isnothing(err) ? nothing : sprint(showerror, err),
                       "cleanup_observed" => cleaned, "output_exists" => isfile(output),
                       "output_bytes" => isfile(output) ? read(output, String) : nothing)
        push!(results, outcome)
        @testset "synthetic $mode" begin
            @test cleaned
            if mode == "success"
                @test isnothing(err)
                @test read(output, String) == "synthetic-output"
            elseif mode == "upload-truncate"
                @test err !== nothing
                @test occursin("truncated", sprint(showerror, err))
                @test !isfile(output)
            elseif mode == "remote-fail"
                @test err !== nothing
                @test !isfile(output)
            else
                @test isnothing(err) # observed: scp exit 0 is trusted on download
                @test read(output, String) == "x"
            end
        end
    end
finally
    ENV["PATH"] = old_path
    isnothing(old_mode) ? delete!(ENV, "FAULT_MODE") : (ENV["FAULT_MODE"] = old_mode)
    delete!(ENV, "FAULT_ROOT"); delete!(ENV, "FAULT_REMOTE"); delete!(ENV, "FAULT_LOG")
end
open(ENV["EVIDENCE_FAULT_JSON"], "w") do io
    JSON3.pretty(io, Dict("schema_version" => 1, "live_network" => false,
        "purpose" => "observe shared RemoteExec behaviour under synthetic transport faults",
        "cases" => results,
        "limitations" => ["does not model real SSH authentication, signals, NFS silly-rename or server reboot"]))
    write(io, "\n")
end
