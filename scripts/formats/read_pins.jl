# SPDX-License-Identifier: MPL-2.0
# Read and validate the immutable ijson-jcs reference pins for the format-readiness
# workflow. Run from the repository root; appends `revision=` and `rust=` lines to
# the file named by GITHUB_OUTPUT. Exits 1 with a short message on any bad pin.
using TOML

function fail(message)
    println(stderr, message)
    exit(1)
end

pin = TOML.parsefile("config/format-tools.toml")["ijson_jcs"]
pin["repository"] == "https://github.com/hyperpolymath/ijson-jcs" ||
    fail("unexpected reference repository")
occursin(r"^[0-9a-f]{40}\z", pin["revision"]) || fail("reference must be an immutable commit")
occursin(r"^[0-9]+\.[0-9]+\.[0-9]+\z", pin["rust_toolchain"]) ||
    fail("Rust must be an explicit release")
open(ENV["GITHUB_OUTPUT"], "a") do stream
    write(stream, "revision=$(pin["revision"])\nrust=$(pin["rust_toolchain"])\n")
end
