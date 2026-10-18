# SPDX-License-Identifier: MPL-2.0
using Test, JSON3
if !isdefined(@__MODULE__, :PlacementEvidence)
    include(joinpath(@__DIR__, "../../src/evidence/placement.jl"))
end
const PE = PlacementEvidence
function evidence_fixture(; weights=[0.6,0.4], names=Dict("n"=>["q"]), fields=["edge_num","like_weight_ratio"], tree="((A{0},B{1}){2},C{3},D{4}){5};")
    Dict("version"=>3,"tree"=>tree,"fields"=>fields,
         "placements"=>[merge(Dict("p"=>[Any[i-1,w] for (i,w) in enumerate(weights)]),names)])
end
@testset "Placement evidence identity" begin
    for v in JSON3.read(read(joinpath(@__DIR__,"../fixtures/evidence/split-vectors.json"),String))
        ix=PE.treeindex(v.tree)
        @test Dict(e.edge=>String(e.split) for e in v.edges)==Dict(e=>v.split for (e,v) in ix.edges)
    end
    @test_throws ArgumentError PE.treeindex("(A{0},A{1},A#2{2});")
    @test_throws ArgumentError PE.treeindex("(A{0},B{0},C{2});")
    @test_throws ArgumentError PE.treeindex("((A,B);")
    @test_throws ArgumentError PE.treeindex("(A,B);garbage")
end
@testset "Raw placement predicate" begin
    ck(d;kw...)=PE.check(JSON3.write(d);kw...)
    @test only(ck(evidence_fixture()).queries).verdict=="fails"
    @test only(ck(evidence_fixture(weights=[0.95,0.05])).queries).verdict=="holds"
    @test only(ck(evidence_fixture(weights=[0.9499999,0.0500001])).queries).verdict=="fails"
    @test only(ck(evidence_fixture(weights=[0.5,0.5]);threshold=0.5).queries).best==[0,1]
    @test_throws ArgumentError ck(evidence_fixture();threshold=true)
    @test_throws ArgumentError ck(evidence_fixture();threshold=0)
    @test_throws ArgumentError ck(evidence_fixture();threshold=NaN)
    for w in ([0.6],[-0.1,1.1],[0,0],[nothing,1],["0.6",0.4],Any[true,0])
        @test only(ck(evidence_fixture(weights=w)).queries).verdict=="undecided"
    end
    for fields in (["edge_num"],["edge_num","edge_num"],["edge_num","like_weight_ratio","like_weight_ratio"])
        @test only(ck(evidence_fixture(fields=fields)).queries).verdict=="undecided"
    end
    for names in (Dict("n"=>["q"],"nm"=>[["q",1]]),Dict("n"=>["q","q"]),Dict("nm"=>[["q",-1]]))
        @test only(ck(evidence_fixture(names=names)).queries).verdict=="undecided"
    end
    d=evidence_fixture();d["placements"][1]["p"][1][1]=5
    @test only(ck(d).queries).verdict=="undecided" # source root is not a physical edge
    d=evidence_fixture();d["placements"][1]["p"][2][1]=0
    @test only(ck(d).queries).verdict=="undecided"
    @test only(ck(evidence_fixture(names=Dict("nm"=>[["q",3],["r",2]]))).queries).aliases[1].multiplicity==3
end
@testset "Raw to accumulated mapping" begin
    raw=JSON3.write(evidence_fixture())
    target=JSON3.write(evidence_fixture(weights=[1]))
    @test only(PE.mapping(raw,target)).target.edge_num==0
    @test only(PE.check(raw).queries).verdict=="fails"
    @test only(PE.mapping(raw,JSON3.write(evidence_fixture(names=Dict("n"=>["other"]))))).target===nothing
    @test_throws ArgumentError PE.mapping(raw,JSON3.write(evidence_fixture(tree="(A{0},B{1},C{2},D{3});")))
end
