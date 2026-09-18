# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# Disposable API fixture. NOT the scientific backend; never reads or writes studies.
using HTTP, JSON3
const STUDIES = [
    (; name="fixture_coastal", run_count=2, group_count=1, active_job_count=0),
    (; name="fixture_empty", run_count=0, group_count=0, active_job_count=0),
]
json(status, x) = HTTP.Response(status, ["Content-Type"=>"application/json"], JSON3.write(x))
function handler(req)
    req.method == "GET" || return json(405, (; error="read_only_fixture"))
    path = HTTP.URI(req.target).path
    path == "/api/v1/studies" && return json(200, STUDIES)
    path == "/api/v1/studies/malformed" && return json(200, (; name="bad"))
    path == "/api/v1/studies/invalid_json" && return HTTP.Response(200, "not json")
    path == "/api/v1/studies/redirect" && return HTTP.Response(302, ["Location"=>"http://127.0.0.1:1"], "{}")
    for s in STUDIES
        if path == "/api/v1/studies/" * s.name
            return json(200, merge(s, (; runs=s.run_count == 0 ? String[] : ["run_A", "run_B"],
                                      groups=s.group_count == 0 ? String[] : ["batch_1"])))
        end
    end
    json(404, (; error="study_not_found"))
end
println("Disposable MetaManifold API fixtures on 127.0.0.1:18080")
HTTP.serve(handler, "127.0.0.1", 18080)
