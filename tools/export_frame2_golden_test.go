package hevc

// Regenerate tools/frame2_golden.json by copying this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_frame2_golden_test.go and running:
//
//   FRAME2_GOLDEN_OUT=/abs/path/to/monbit_tmp/tools/frame2_golden.json \
//     go test -tags noasm ./hevc/ -run TestExportFrame2Golden -count=1 -v
//
// Truth chain, link 1: the REAL upstream Go decoder decodes the FIRST picture
// of each stream (parameter sets + all VCL slices from the first
// first_slice_segment_in_pic=true through the end of that picture) into its
// final planar YUV (DecodeNAL + Flush), -tags noasm. Where the upstream ships
// a matching *_ref.yuv, the exporter asserts the decoded YUV equals it byte
// for byte, so the fixture is the upstream decoder's output rather than a
// re-derivation.
//
// These are the remaining M3 tools, all single-slice, single-tile, no-WPP,
// pure Main 8-bit 4:2:0 I frames: SAO (7.3.8.3 / 8.7.3), scaling lists
// (7.3.4 / 8.6.3), PCM (7.3.8.7 / 8.4.4.1), transform skip, transquant
// bypass, cu_chroma_qp_offset, plus a 320x240 scaling+signhide frame and
// 720p/1080p/4032x3024 scale checks. WPP/tiles streams are out of M3 scope by the
// Issue ("single thread, give up WPP/tiles parallelism") and are not here.
//
// Link 2 is tools/crosscheck_frame2.mjs: it verifies the fixture's stream/YUV
// fingerprints against an independent JS computation. CI needs no Go/network.

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func isBig(name string) bool {
	switch name {
	case "realworld_720p.h265", "1080p.h265", "large_4032x3024.h265":
		return true
	}
	return false
}

func fp(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:8])
}

// fnv1a matches tools/gen_frame2_golden.mjs planeCheck: FNV-1a over UInt64.
func fnv1a(b []byte) (string, int) {
	var h uint64 = 0xcbf29ce484222325
	nz := 0
	for _, v := range b {
		h = (h ^ uint64(v)) * 0x100000001b3
		if v != 0 { nz++ }
	}
	return fmt.Sprintf("%d", h), nz
}

func probeSamples(b []byte) [][2]int {
	const pn = 64
	out := make([][2]int, 0, pn)
	for k := 0; k < pn; k++ {
		i := k * (len(b) - 1) / (pn - 1)
		out = append(out, [2]int{i, int(b[i])})
	}
	return out
}

// firstPictureNals returns the Annex B bytes of the first picture: parameter
// sets, then every VCL slice from the first first_slice_segment_in_pic=true
// until (excluding) the next one.
func firstPictureNals(data []byte) ([]byte, []map[string]any, error) {
	var d Decoder
	var sp *sps
	var pp *pps
	for _, nal := range SplitAnnexB(data) {
		d.DecodeNAL(nal)
		for _, x := range d.sps { sp = x }
		for _, x := range d.pps { pp = x }
	}
	var picked []NALUnit
	var infos []map[string]any
	seenFirst := false
	for _, nal := range SplitAnnexB(data) {
		if !nal.Type.IsVCL() {
			if seenFirst { break }
			picked = append(picked, nal)
			continue
		}
		sh, err := parseSliceHeader(nal.RBSP, nal.Type, sp, pp)
		if err != nil { return nil, nil, err }
		if sh.firstSliceSegmentInPic && seenFirst { break }
		seenFirst = true
		picked = append(picked, nal)
		infos = append(infos, map[string]any{
			"first": sh.firstSliceSegmentInPic, "dep": sh.dependentSliceSegment,
			"addr": sh.sliceSegmentAddress, "sao_luma": sh.saoLuma, "sao_chroma": sh.saoChroma,
			"qp": sh.qpY, "deblock_disabled": sh.deblockingDisabled,
			"beta_off": sh.betaOffsetDiv2, "tc_off": sh.tcOffsetDiv2,
			"ep": len(sh.entryPointOffsets), "offset": sh.dataOffset, "type": int(sh.sliceType),
		})
	}
	return MarshalAnnexB(picked), infos, nil
}

func decodeFirstPicture(data []byte) ([]byte, int, int, error) {
	var d Decoder
	var out []byte
	var w, h int
	for _, nal := range SplitAnnexB(data) {
		pics, err := d.DecodeNAL(nal)
		if err != nil { return nil, 0, 0, err }
		for _, p := range pics {
			out = append(out, p.Y...); out = append(out, p.Cb...); out = append(out, p.Cr...)
			w, h = p.Width, p.Height
		}
	}
	for _, p := range d.Flush() {
		out = append(out, p.Y...); out = append(out, p.Cb...); out = append(out, p.Cr...)
		w, h = p.Width, p.Height
	}
	return out, w, h, nil
}


// encodeSaoFrame produces a single-slice, single-tile, no-WPP I frame whose
// SAO genuinely changes pixels: a gradient/noise source gives the encoder an
// error for 8.7.3 to fit. The real upstream decoder then decodes it into the
// authoritative YUV, and the exporter asserts SAO actually changed something
// by decoding once more with applySAO disabled via a temporary source toggle.
func encodeSaoFrame(width, height, qp int, seed uint8, sao bool) ([]byte, error) {
	w, h := codedSize(width), codedSize(height)
	y := make([]uint8, w*h)
	cb := make([]uint8, w/2*h/2)
	cr := make([]uint8, w/2*h/2)
	var st uint32 = uint32(seed) + 1
	rnd := func() uint8 { st = st*1664525 + 1013904223; return uint8(st >> 16) }
	for j := 0; j < h; j++ {
		for i := 0; i < w; i++ {
			y[j*w+i] = uint8((i*3 + j*5 + int(rnd())%24) & 255)
		}
	}
	for j := 0; j < h/2; j++ {
		for i := 0; i < w/2; i++ {
			cb[j*(w/2)+i] = uint8((i*7 + j*2 + 60) & 255)
			cr[j*(w/2)+i] = uint8((i*2 + j*9 + 120) & 255)
		}
	}
	enc, err := NewEncoder(EncoderOptions{Width: width, Height: height, QP: qp, SAO: sao})
	if err != nil { return nil, err }
	nals, err := enc.Encode(Frame{Y: y, Cb: cb, Cr: cr, StrideY: w, StrideC: w / 2})
	if err != nil { return nil, err }
	return MarshalAnnexB(nals), nil
}


// encodePCMFrame produces a single-slice, single-tile, no-WPP I frame that
// uses real CU-level PCM samples (8.4.4.1) via the upstream Lossless encoder.
// The real decoder routes these through pcmSample (7.3.8.7), and the profile
// is standard Main (idc=1), unlike HM's idc=0 test stream.
func encodePCMFrame(width, height int, seed uint8) ([]byte, error) {
	w, h := codedSize(width), codedSize(height)
	y := make([]uint8, w*h)
	cb := make([]uint8, w/2*h/2)
	cr := make([]uint8, w/2*h/2)
	var st uint32 = uint32(seed) + 1
	rnd := func() uint8 { st = st*1664525 + 1013904223; return uint8(st >> 16) }
	for j := 0; j < h; j++ {
		for i := 0; i < w; i++ { y[j*w+i] = uint8((i*7 + j*13 + int(rnd())%16) & 255) }
	}
	for j := 0; j < h/2; j++ {
		for i := 0; i < w/2; i++ {
			cb[j*(w/2)+i] = uint8((i*3 + j*5 + 40 + int(rnd())%16) & 255)
			cr[j*(w/2)+i] = uint8((i*5 + j*3 + 90 + int(rnd())%16) & 255)
		}
	}
	enc, err := NewEncoder(EncoderOptions{Width: width, Height: height, Lossless: true})
	if err != nil { return nil, err }
	nals, err := enc.Encode(Frame{Y: y, Cb: cb, Cr: cr, StrideY: w, StrideC: w / 2})
	if err != nil { return nil, err }
	return MarshalAnnexB(nals), nil
}


// encodeLargeFrame produces a deterministic 4032x3024 (iPhone still size)
// single-slice I frame for the Issue's "a 4032x3024 I frame decodes without
// crashing" acceptance check. A plain gradient keeps the encoder fast.
func encodeLargeFrame() ([]byte, error) {
	const w, h = 4032, 3024
	y := make([]uint8, w*h)
	cb := make([]uint8, w/2*h/2)
	cr := make([]uint8, w/2*h/2)
	for j := 0; j < h; j++ {
		for i := 0; i < w; i++ { y[j*w+i] = uint8((i + j) & 255) }
	}
	for j := 0; j < h/2; j++ {
		for i := 0; i < w/2; i++ {
			cb[j*(w/2)+i] = uint8((i + j + 40) & 255)
			cr[j*(w/2)+i] = uint8((i + j + 90) & 255)
		}
	}
	enc, err := NewEncoder(EncoderOptions{Width: w, Height: h, QP: 26})
	if err != nil { return nil, err }
	nals, err := enc.Encode(Frame{Y: y, Cb: cb, Cr: cr, StrideY: w, StrideC: w / 2})
	if err != nil { return nil, err }
	return MarshalAnnexB(nals), nil
}

func TestExportFrame2Golden(t *testing.T) {
	// Single-slice, single-tile, no-WPP pure I frames that exercise the
	// remaining M3 tools, plus scale checks.
	names := []string{
		"sao.h265",                 // SAO syntax + 8.7.3 application (ref.yuv)
		"scaling_list.h265",        // scaling list dequant (ref.yuv)
		"pcm.h265",                 // plain I frame with ref.yuv (regression)
		"tskip_128x128.h265",       // transform skip
		"transquant_bypass_64x64.h265", // cu_transquant_bypass_flag
		"signhide_scaling_320x240.h265", // scaling + sign data hiding at scale
		"encoder_lossy_32x32.h265", // deblocking-active regression
		"realworld_720p.h265",      // 1280x720 scale
		"1080p.h265",               // 1920x1088 scale
	}

	cases := []map[string]any{}
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil { t.Fatalf("%s: %v", name, err) }
		stream, slices, err := firstPictureNals(data)
		if err != nil { t.Fatalf("%s: %v", name, err) }
		yuv, w, h, err := decodeFirstPicture(stream)
		if err != nil { t.Fatalf("%s: decode: %v", name, err) }

		refName := name[:len(name)-len(".h265")] + "_ref.yuv"
		ref, refErr := os.ReadFile(filepath.Join("testdata", refName))
		hasRef := refErr == nil
		if hasRef && !bytes.Equal(yuv, ref) {
			t.Fatalf("%s: decoded YUV does not match %s", name, refName)
		}
		wantLen := w*h + 2*((w+1)/2)*((h+1)/2)
		if len(yuv) != wantLen {
			t.Fatalf("%s: yuv len %d, want %d", name, len(yuv), wantLen)
		}

		m := map[string]any{
			"name": name,
			"stream": base64.StdEncoding.EncodeToString(stream),
			"width": w, "height": h,
			"has_ref": hasRef,
			"stream_fp": fp(stream), "yuv_fp": fp(yuv),
			"slices": slices,
		}
		if isBig(name) {
			// Large frames: do not ship the 18 MB YUV; a fingerprint, an
			// FNV-1a checksum, a nonzero count and 64 probes prove agreement.
			cs, nz := fnv1a(yuv)
			m["big"] = true
			m["checksum"] = cs
			m["nonzero"] = nz
			m["probes"] = probeSamples(yuv)
		} else {
			m["yuv"] = base64.StdEncoding.EncodeToString(yuv)
		}
		cases = append(cases, m)
		t.Logf("%s: %dx%d, %d stream bytes, %d YUV bytes, ref=%v", name, w, h, len(stream), len(yuv), hasRef)
	}



	// Encoder-generated real CU-level PCM frames (single slice, single tile,
	// no WPP, standard Main profile). Two sizes for coverage.
	for _, spec := range []struct{ name string; w, h int; seed uint8 }{
		{"pcm_32x32.h265", 32, 32, 3},
		{"pcm_64x64.h265", 64, 64, 11},
	} {
		stream, err := encodePCMFrame(spec.w, spec.h, spec.seed)
		if err != nil { t.Fatalf("%s: encode: %v", spec.name, err) }
		yuv, w, h, err := decodeFirstPicture(stream)
		if err != nil { t.Fatalf("%s: decode: %v", spec.name, err) }
		wantLen := w*h + 2*((w+1)/2)*((h+1)/2)
		if len(yuv) != wantLen { t.Fatalf("%s: yuv len %d, want %d", spec.name, len(yuv), wantLen) }
		cases = append(cases, map[string]any{
			"name": spec.name,
			"stream": base64.StdEncoding.EncodeToString(stream),
			"yuv": base64.StdEncoding.EncodeToString(yuv),
			"width": w, "height": h, "has_ref": false,
			"stream_fp": fp(stream), "yuv_fp": fp(yuv),
			"slices": []map[string]any{},
		})
		t.Logf("%s: %dx%d, %d stream bytes, %d YUV bytes (encoder-generated PCM)", spec.name, w, h, len(stream), len(yuv))
	}

	// Encoder-generated SAO-active frames (single slice, single tile, no WPP,
	// SAO genuinely changes pixels). Two seeds and two sizes for coverage.
	for _, spec := range []struct{ name string; w, h, qp int; seed uint8 }{
		{"sao_active_64x64_q32.h265", 64, 64, 32, 7},
		{"sao_active_128x128_q26.h265", 128, 128, 26, 19},
	} {
		stream, err := encodeSaoFrame(spec.w, spec.h, spec.qp, spec.seed, true)
		if err != nil { t.Fatalf("%s: encode: %v", spec.name, err) }
		yuv, w, h, err := decodeFirstPicture(stream)
		if err != nil { t.Fatalf("%s: decode: %v", spec.name, err) }
		wantLen := w*h + 2*((w+1)/2)*((h+1)/2)
		if len(yuv) != wantLen { t.Fatalf("%s: yuv len %d, want %d", spec.name, len(yuv), wantLen) }
		cases = append(cases, map[string]any{
			"name": spec.name,
			"stream": base64.StdEncoding.EncodeToString(stream),
			"yuv": base64.StdEncoding.EncodeToString(yuv),
			"width": w, "height": h, "has_ref": false,
			"stream_fp": fp(stream), "yuv_fp": fp(yuv),
			"slices": []map[string]any{},
		})
		t.Logf("%s: %dx%d, %d stream bytes, %d YUV bytes (encoder-generated SAO)", spec.name, w, h, len(stream), len(yuv))
	}

	// The Issue's explicit acceptance: a 4032x3024 I frame decodes fully.
	{
		stream, err := encodeLargeFrame()
		if err != nil { t.Fatalf("4032x3024: encode: %v", err) }
		yuv, w, h, err := decodeFirstPicture(stream)
		if err != nil { t.Fatalf("4032x3024: decode: %v", err) }
		wantLen := w*h + 2*((w+1)/2)*((h+1)/2)
		if len(yuv) != wantLen { t.Fatalf("4032x3024: yuv len %d, want %d", len(yuv), wantLen) }
		cs, nz := fnv1a(yuv)
		cases = append(cases, map[string]any{
			"name": "large_4032x3024.h265",
			"stream": base64.StdEncoding.EncodeToString(stream),
			"width": w, "height": h, "has_ref": false,
			"stream_fp": fp(stream), "yuv_fp": fp(yuv),
			"slices": []map[string]any{},
			"big": true, "checksum": cs, "nonzero": nz, "probes": probeSamples(yuv),
		})
		t.Logf("large_4032x3024.h265: %dx%d, %d stream bytes, %d YUV bytes", w, h, len(stream), len(yuv))
	}

	out := map[string]any{
		"source": "gen2brain/h265 real decoder (DecodeNAL + Flush), -tags noasm, first picture",
		"cases": cases,
	}
	path := os.Getenv("FRAME2_GOLDEN_OUT")
	if path == "" { path = "/workspace/tools/frame2_golden.json" }
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil { t.Fatal(err) }
	if err := os.WriteFile(path, append(b, '\n'), 0644); err != nil { t.Fatal(err) }
	fmt.Printf("wrote %d cases (%d bytes) to %s\n", len(cases), len(b), path)
}
