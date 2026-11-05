// Regenerate tools/deblock_golden.json by copying this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_deblock_golden_test.go and running:
//
//   go test -tags noasm ./hevc/ -run TestExportDeblock -count=1 -v
//
// Truth chain, link 1: the REAL upstream Go decoder. Two test-only hooks are
// required in the upstream checkout (they are NOT needed at CI time):
//
//   1. in decoder.go, gate the loop filters in finishPicture:
//        if !disableDeblockForProbe { d.ctu.deblock() }
//        if !disableSaoForProbe { d.ctu.applySAO() }
//      with two package-level bools, so the same stream can be decoded with
//      and without filtering (full vs plain).
//   2. call a hook just before deblock() with the real ctuDecoder state:
//        if deblockStateProbe != nil { deblockStateProbe(d.ctu) }
//      where the hook (installed by this test) snapshots blk / qpY /
//      noFilter --- the exact 4x4-raster state upstream deblock() consumed.
//
// Each frame is decoded by DecodeNAL + Flush into final planar YUV (WITH
// filtering => `full`), then again with filters disabled (`plain`). Where the
// upstream ships a matching *_ref.yuv, the exporter asserts the filtered YUV
// equals it byte for byte. `state` is the real upstream deblock state, an
// independent oracle for tools/crosscheck_deblock.mjs.
//
// Link 2 is tools/crosscheck_deblock.mjs: it re-derives the fixture's full/
// plain fingerprints, changed-sample count, and the spec invariants of the
// captured block state. Link 3 is tools/gen_deblock_golden.mjs, which emits
// the self-contained MoonBit fixture; MoonBit decode_i_frame must reproduce
// `full` byte for byte. CI needs no Go/network.

package hevc

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

type deblockState struct {
	MvW int `json:"mv_w"`
	MvH int `json:"mv_h"`
	// per 4x4 block, flattened: intra/cbf/tuV/tuH/puV/puH
	Intra []bool `json:"intra"`
	Cbf []bool `json:"cbf"`
	TuV []bool `json:"tu_v"`
	TuH []bool `json:"tu_h"`
	PuV []bool `json:"pu_v"`
	PuH []bool `json:"pu_h"`
	// min-TB grid (4x4) QP and noFilter
	QpY []int `json:"qp_y"`
	NoFilter []bool `json:"no_filter"`
}

type deblockCase struct {
	Name string `json:"name"`
	Stream string `json:"stream"`
	W int `json:"w"`
	H int `json:"h"`
	Full string `json:"full"`   // decoded YUV WITH deblock+SAO
	Plain string `json:"plain"`  // decoded YUV with deblock+SAO disabled
	BetaOff int32 `json:"beta_off"`
	TcOff int32 `json:"tc_off"`
	DeblockDisabled bool `json:"deblock_disabled"`
	SaoLuma bool `json:"sao_luma"`
	SaoChroma bool `json:"sao_chroma"`
	State deblockState `json:"state"`
	HasRef bool `json:"has_ref"`
}

func decodeWithState(data []byte, disableD, disableS bool) ([]byte, *deblockState, *sliceHeader, int, int) {
	disableDeblockForProbe, disableSaoForProbe = disableD, disableS
	var captured *deblockState
	deblockStateProbe = func(c *ctuDecoder) {
		n := c.mvWidth * ((int(c.s.picHeightInLumaSamples)+3)/4)
		st := &deblockState{MvW:c.mvWidth, MvH:n/c.mvWidth}
		for i:=0;i<n;i++ {
			b := c.blk[i]
			st.Intra=append(st.Intra,b.intra); st.Cbf=append(st.Cbf,b.cbf)
			st.TuV=append(st.TuV,b.tuV); st.TuH=append(st.TuH,b.tuH)
			st.PuV=append(st.PuV,b.puV); st.PuH=append(st.PuH,b.puH)
		}
		tbn := len(c.qpY)
		for i:=0;i<tbn;i++ { st.QpY=append(st.QpY,int(c.qpY[i])); st.NoFilter=append(st.NoFilter,c.noFilter[i]) }
		captured = st
	}
	defer func(){ disableDeblockForProbe, disableSaoForProbe=false,false; deblockStateProbe=nil }()
	var d Decoder
	var out []byte
	var w,h int
	for _, nal := range SplitAnnexB(data) {
		pics, err := d.DecodeNAL(nal); if err!=nil { return nil,nil,nil,0,0 }
		for _, p := range pics { out=append(out,p.Y...); out=append(out,p.Cb...); out=append(out,p.Cr...) }
	}
	for _, p := range d.Flush() { out=append(out,p.Y...); out=append(out,p.Cb...); out=append(out,p.Cr...) }
	for _, s := range d.sps { w,h=int(s.picWidthInLumaSamples),int(s.picHeightInLumaSamples) }
	return out, captured, d.prevSlic, w, h
}

func TestExportDeblock(t *testing.T) {
	// Single-slice, single-tile, no-WPP, no-SA0, Main 8-bit 4:2:0 I frames
	// where the upstream deblocking filter actually changes pixels.
	names := []string{
		"encoder_lossy_32x32.h265",
		// Regression: these frames have deblocking enabled but it is a no-op
		// (uniform QP / flat gradients), so their full == plain.
		"deblock_grad.h265",
		"tu8.h265", "angular.h265", "multi_ctu.h265", "tiny_intra.h265",
	}
	cases := []deblockCase{}
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil { t.Fatalf("%s: %v", name, err) }
		full, st, sh, w, h := decodeWithState(data, false, false)
		plain, _, _, _, _ := decodeWithState(data, true, true)
		if full==nil || plain==nil || len(full)!=len(plain) { t.Fatalf("%s: bad decode", name) }
		if st==nil { t.Fatalf("%s: no state captured", name) }
		refName := name[:len(name)-len(".h265")]+"_ref.yuv"
		ref, rerr := os.ReadFile(filepath.Join("testdata", refName))
		hasRef := rerr==nil
		if hasRef && string(ref)!=string(full) { t.Fatalf("%s: decoded != ref.yuv", name) }
		c := deblockCase{Name:name,Stream:base64.StdEncoding.EncodeToString(data),W:w,H:h,
			Full:base64.StdEncoding.EncodeToString(full),Plain:base64.StdEncoding.EncodeToString(plain),
			State:*st, HasRef:hasRef}
		if sh!=nil {
			c.BetaOff, c.TcOff = sh.betaOffsetDiv2, sh.tcOffsetDiv2
			c.DeblockDisabled, c.SaoLuma, c.SaoChroma = sh.deblockingDisabled, sh.saoLuma, sh.saoChroma
		}
		changes:=0; for i:=range full { if full[i]!=plain[i] { changes++ } }
		fmt.Printf("%-34s %dx%d changes=%d state=%dx%d ref=%v\n", name,w,h,changes,st.MvW,st.MvH,hasRef)
		cases=append(cases,c)
	}
	b,_:=json.MarshalIndent(cases,"","  ")
	os.WriteFile("/workspace/tools/deblock_golden.json", b, 0644)
}
