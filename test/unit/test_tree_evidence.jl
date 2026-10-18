# SPDX-License-Identifier: MPL-2.0
using Test, JSON3
if !isdefined(@__MODULE__, :SV)
    using MetaManifold
    const SV=MetaManifold.Server
end
function _ev_request(method,path,body=nothing)
    payload=isnothing(body) ? "" : JSON3.write(body)
    SV.Oxygen.internalrequest(SV.HTTP.Request(method,path,["Content-Type"=>"application/json"],payload))
end
_ev_json(r)=JSON3.read(String(r.body))
@testset "Evidence routes and source lifecycle" begin
    tmp=mktempdir();old=SV.ServerState._root[];SV.ServerState.set_root!(tmp)
    try
        for study in ("S","Other");mkpath(joinpath(tmp,"projects",study));end
        base="/api/v1/studies/S/trees";file="raw.jplace";target="acc.jplace"
        doc=Dict("tree"=>"((A{0},B{1}){2},C{3},D{4}){5};",
                 "fields"=>["edge_num","like_weight_ratio"],
                 "placements"=>[Dict("n"=>["q"],"p"=>[[0,0.6],[1,0.4]])])
        raw=JSON3.write(doc);acc=deepcopy(doc);acc["placements"][1]["p"]=[[2,1.0]]
        upload(f,t;overwrite=false)=_ev_request("POST",base,Dict("file"=>f,"content"=>t,"overwrite"=>overwrite))
        @test upload(file,raw).status==200
        @test upload(target,JSON3.write(acc)).status==200
        @test _ev_json(_ev_request("GET","$base/$file/evidence")).state=="missing"
        body=Dict("source_sha256"=>SV._digest(raw),"threshold"=>0.95,"confirm_raw"=>true,"accumulated_file"=>target)
        @test _ev_request("POST","$base/$file/evidence",merge(body,Dict("source_sha256"=>"bad"))).status==400
        @test _ev_request("POST","$base/$file/evidence",merge(body,Dict("confirm_raw"=>false))).status==400
        got=_ev_request("POST","$base/$file/evidence",body)
        @test got.status==200
        r=_ev_json(got);@test r.state=="ready"
        @test r.result.queries[1].verdict=="fails"
        @test r.mapping[1].target.edge_num==2
        r=_ev_json(_ev_request("GET","$base/$target/evidence"))
        @test r.state=="ready" && r.role=="accumulated"
        @test r.result.queries[1].verdict=="fails" # accumulated LWR=1 is never substituted
        @test _ev_request("POST","$base/$target/evidence",body).status==400
        @test _ev_json(_ev_request("GET","/api/v1/studies/Other/trees/$file/evidence")).state=="missing"
        @test _ev_request("GET","/api/v1/studies/Absent/trees/$file/evidence").status==404
        @test _ev_request("POST","$base/$file/evidence",merge(body,Dict("threshold"=>true))).status==400
        # Tampering cannot introduce a fabricated scientific result.
        p=SV._evidence_path("S",file);side=JSON3.read(read(p,String),Dict{String,Any})
        side["result"]["queries"][1]["verdict"]="holds";write(p,JSON3.write(side))
        @test _ev_json(_ev_request("GET","$base/$file/evidence")).state=="invalid"
        @test _ev_request("POST","$base/$file/evidence",body).status==200
        # Out-of-band file replacement is still detected by hashes on read.
        write(joinpath(SV._trees_dir("S"),target),JSON3.write(doc))
        @test _ev_json(_ev_request("GET","$base/$target/evidence")).state=="stale"
        @test _ev_json(_ev_request("GET","$base/$file/evidence")).state=="ready"
        write(joinpath(SV._trees_dir("S"),file),raw*"\n")
        @test _ev_json(_ev_request("GET","$base/$file/evidence")).state=="stale"
        @test upload(file,raw;overwrite=true).status==200
        @test !isfile(p)
        @test _ev_json(_ev_request("GET","$base/$file/evidence")).state=="missing"
        @test _ev_request("DELETE","$base/$file").status==200
        @test !isfile(SV._origin_path("S",file))
        @test _ev_request("POST","$base/$file/evidence",body).status==400
        @test !isdir(joinpath(tmp,"reference_trees"))
    finally
        SV.ServerState.set_root!(old);rm(tmp;force=true,recursive=true)
    end
end

@testset "Pipeline evidence source publication" begin
    tmp=mktempdir();old=SV.ServerState._root[];SV.ServerState.set_root!(tmp)
    try
        mkpath(joinpath(tmp,"projects","S"));files=Dict{String,String}()
        for name in ("reference.treefile","placement.jplace","accumulated.jplace")
            files[name]=joinpath(tmp,name)
            write(files[name],name=="reference.treefile" ? "(A,B,C);" : JSON3.write(Dict(
                "tree"=>"(A{0},B{1},C{2});","fields"=>["edge_num","like_weight_ratio"],"placements"=>[])))
        end
        published=SV._publish_placement("S","test","ref",files)
        @test length(published)==3
        @test SV._tree_origin("S","test.jplace")["role"]=="raw"
        @test SV._tree_origin("S","test-accumulated.jplace")["role"]=="accumulated"
        @test SV._read_evidence("S","ref.treefile").state=="not_applicable"
        @test !isdir(joinpath(tmp,"reference_trees"))
    finally
        SV.ServerState.set_root!(old);rm(tmp;force=true,recursive=true)
    end
end
