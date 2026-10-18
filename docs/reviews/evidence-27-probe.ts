// SPDX-License-Identifier: MPL-2.0
// Audit probes reproduce existing behaviour; they are not feature acceptance tests.
import {strict as a} from 'node:assert';
import {indexTree,parseNewick,parseJplace,buildDisplay,foldOps,toNewick} from '../../frontend/src/tree/model';
const splitSet=(s:any)=>[...indexTree(s).splitEdge.keys()].sort();
let checks=0;
const check=(name:string,f:()=>void)=>{f();checks++;console.log('PASS '+name)};
check('unique-name reroot preserves split IDs',()=>{
 const s=parseNewick('((A:1,B:1):1,C:1,D:1);'),ix=indexTree(s);
 a.deepEqual(splitSet(parseNewick(toNewick(buildDisplay(ix,foldOps([{op:'reroot',split:ix.split[2],at:0.5}]),new Map()),'support',true))),splitSet(s));
});
check('reference and edge-numbered placement share IDs',()=>a.deepEqual(splitSet(parseNewick('((A,B),C,D);')),splitSet(parseNewick('((A{0},B{1}){2},C{3},D{4}){5};'))));
check('degree-two root repeats split IDs',()=>{const s=parseNewick('((A,B),(C,D));');a.ok(indexTree(s).splitEdge.size<s.nodes.length-1)});
check('unary chain repeats split IDs',()=>{const s=parseNewick('(((A,B)),C,D);');a.ok(indexTree(s).splitEdge.size<s.nodes.length-1)});
check('literal suffix collides with generated key',()=>{const s=parseNewick('(A,A,A#2);');a.equal(new Set(indexTree(s).tipKey.filter(Boolean)).size,2)});
check('display parser defaults missing LWR to 1',()=>{const s=parseJplace(JSON.stringify({tree:'(A{0},B{1},C{2});',fields:['edge_num'],placements:[{n:['q'],p:[[0]]}]}));a.equal(s.pqueries[0].places[0].lwr,1)});
check('duplicate edge number overwrites index',()=>{a.equal(indexTree(parseNewick('(A{0},B{0},C{2});')).edgeByNum.size,2)});
check('UTF-16 and scalar ordering differ',()=>{a.ok('\u{10000}'<'\uE000');a.ok('\u{10000}'.codePointAt(0)!>'\uE000'.codePointAt(0)!)});
console.log(checks+' contract probes passed (hazard reproduction, not implementation conformance)');
