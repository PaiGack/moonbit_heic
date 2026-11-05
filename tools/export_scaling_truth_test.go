package hevc

// Regenerate tools/scaling_truth.json by copying this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_scaling_truth_test.go and running:
//
//   SCALING_TRUTH_OUT=/abs/path/to/monbit_tmp/tools/scaling_truth.json \\
//     go test -tags noasm ./hevc/ -run TestZZScaling -count=1 -v
//
// Truth chain, link 1: the REAL upstream Go decoder (DecodeNAL + Flush) parses
// each scaling-list stream's SPS, then this exporter reads the raw
// sps.scalingList (sl[4][6][64] and dc[2][6]) and calls the upstream
// unexported scalingList.factors() (7.4.5) to produce the derived matrices.
// Link 2 is tools/crosscheck_scaling.mjs, which re-derives all 16384 values
// from an independent JS transcription (no Go/network).

import("fmt";"os";"testing";"encoding/json";"path/filepath")
func TestZZScaling(t *testing.T){
 out:=map[string]any{}
 for _,name:=range []string{"scaling_list.h265","signhide_scaling_320x240.h265"}{
  data,_:=os.ReadFile(filepath.Join("testdata",name))
  var d Decoder
  for _,nal:=range SplitAnnexB(data){d.DecodeNAL(nal)}
  d.Flush()
  var s *sps; for _,x:=range d.sps{s=x}
  sl:=s.scalingList
  // sl raw
  rawSl:=[][][]int{}
  for si:=range sl.sl{ m:=[][]int{}; for mi:=range sl.sl[si]{a:=[]int{};for _,v:=range sl.sl[si][mi][:]{a=append(a,int(v))};m=append(m,a)}; rawSl=append(rawSl,m) }
  rawDc:=[][]int{}
  for di:=range sl.dc{a:=[]int{};for _,v:=range sl.dc[di]{a=append(a,int(v))};rawDc=append(rawDc,a)}
  f:=sl.factors()
  fac:=[][][]int{}
  for si:=range f{m:=[][]int{};for mi:=range f[si]{a:=[]int{};for _,v:=range f[si][mi]{a=append(a,int(v))};m=append(m,a)};fac=append(fac,m)}
  out[name]=map[string]any{"sl":rawSl,"dc":rawDc,"factors":fac}
  fmt.Printf("SCALING %s sl_sizes=%d fac_sizes=%d\n",name,len(rawSl),len(fac))
 }
 b,_:=json.MarshalIndent(out,"","  ");outPath:=os.Getenv("SCALING_TRUTH_OUT")
 if outPath==""{outPath="/workspace/tools/scaling_truth.json"}
 os.WriteFile(outPath,b,0644)
}
