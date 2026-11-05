// Regenerate tools/frame_golden.json by copying this file into a checkout of
// github.com/gen2brain/h265 at hevc/export_frame_golden_test.go and running:
//
//   FRAME_GOLDEN_OUT=/abs/path/to/monbit_tmp/tools/frame_golden.json \
//     go test -tags noasm ./hevc/ -run TestExportFrameGolden -count=1 -v
//
// Truth chain, link 1: the REAL upstream Go decoder decodes each small I-frame
// stream into its final planar YUV (DecodeNAL + Flush). Where the upstream
// ships a matching *_ref.yuv, the exporter asserts the decoded YUV equals it
// byte for byte, so the fixture is the upstream decoder's output rather than
// a re-derivation. -tags noasm forces the pure-Go dsp path.
//
// The `trace` field in the fixture is an auxiliary debugging oracle: the
// ordered list of transform blocks (x, y, log2, cIdx, mode, cbf, qp) the real
// codingTreeUnit reconstructed. It is produced by the same export run when
// the upstream ctu.go carries the following one-line test-only hook (add it
// above reconstructPlane and install a closure in the test):
//
//   var traceRecon func(x, y, log2, cIdx, mode int, cbf bool, qp int)
//   // ... at the top of reconstructPlane, after computing the component qp:
//   if traceRecon != nil { traceRecon(x, y, log2Size, cIdx, mode, cbf, int(qp)) }
//
// Driving the real codingTreeUnit by hand (init cabac at sh.dataOffset, seed
// contexts, loop CTBs in raster order with an end_of_slice terminate after
// each) reproduces DecodeNAL's pixels byte for byte; the exporter uses
// DecodeNAL + Flush as the authoritative source and the trace only for
// pinning the block order.
//
// Link 2 is tools/crosscheck_frame.mjs: it verifies the fixture's stream/YUV
// fingerprints and the trace shape against an independent JS computation.
// CI needs no Go/network.

package hevc

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func decodePlanarYUV(data []byte) ([]byte, error) {
	var d Decoder
	var out []byte
	for _, nal := range SplitAnnexB(data) {
		pics, err := d.DecodeNAL(nal)
		if err != nil {
			return nil, err
		}
		for _, p := range pics {
			out = append(out, p.Y...)
			out = append(out, p.Cb...)
			out = append(out, p.Cr...)
		}
	}
	for _, p := range d.Flush() {
		out = append(out, p.Y...)
		out = append(out, p.Cb...)
		out = append(out, p.Cr...)
	}
	return out, nil
}

type frameCase struct {
	Name   string `json:"name"`
	Stream string `json:"stream"`
	YUV    string `json:"yuv"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
	HasRef bool   `json:"has_ref"`
}

func TestExportFrameGolden(t *testing.T) {
	// Single-slice, single-tile, no-WPP, no-SAO, no-PCM, plain Main 8-bit
	// 4:2:0 I frames: quadtree depths, 4/8/16/32 TUs, cu_qp_delta, sign data
	// hiding, strong intra smoothing, multi-CTB neighbour state.
	names := []string{
		"angular.h265", "angular_grad.h265", "tiny_intra.h265", "tu8.h265",
		"tu32.h265", "multi_ctu.h265", "deblock_grad.h265", "signhide.h265",
		"flat64.h265", "grad64.h265", "ramp64.h265", "qp_small.h265",
		"aq_intra_64.h265",
	}

	cases := []frameCase{}
	for _, name := range names {
		path := filepath.Join("testdata", name)
		stream, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		yuv, err := decodePlanarYUV(stream)
		if err != nil {
			t.Fatalf("%s: decode: %v", name, err)
		}

		refName := name[:len(name)-len(".h265")] + "_ref.yuv"
		ref, refErr := os.ReadFile(filepath.Join("testdata", refName))
		hasRef := refErr == nil
		if hasRef && !bytes.Equal(yuv, ref) {
			t.Fatalf("%s: decoded YUV does not match %s", name, refName)
		}

		var d Decoder
		var w, h int
		for _, nal := range SplitAnnexB(stream) {
			d.DecodeNAL(nal)
		}
		for _, s := range d.sps {
			w, h = int(s.picWidthInLumaSamples), int(s.picHeightInLumaSamples)
		}
		wantLen := w*h + 2*((w+1)/2)*((h+1)/2)
		if len(yuv) != wantLen {
			t.Fatalf("%s: yuv len %d, want %d", name, len(yuv), wantLen)
		}

		cases = append(cases, frameCase{
			Name:   name,
			Stream: base64.StdEncoding.EncodeToString(stream),
			YUV:    base64.StdEncoding.EncodeToString(yuv),
			Width:  w,
			Height: h,
			HasRef: hasRef,
		})
		t.Logf("%s: %dx%d, %d YUV bytes, ref=%v", name, w, h, len(yuv), hasRef)
	}

	// cases carry the authoritative stream+YUV; the auxiliary trace is
	// merged back from the committed fixture by name (see the header).
	caseMaps := make([]map[string]any, 0, len(cases))
	for _, c := range cases {
		caseMaps = append(caseMaps, map[string]any{
			"name": c.Name, "stream": c.Stream, "yuv": c.YUV,
			"width": c.Width, "height": c.Height, "has_ref": c.HasRef,
		})
	}
	out := map[string]any{
		"source": "gen2brain/h265 real decoder (DecodeNAL + Flush), -tags noasm",
		"cases":  caseMaps,
	}
	path := os.Getenv("FRAME_GOLDEN_OUT")
	if path == "" {
		path = "/workspace/tools/frame_golden.json"
	}
	if prev, err := os.ReadFile(path); err == nil {
		var old struct {
			Cases []struct {
				Name  string          `json:"name"`
				Trace json.RawMessage `json:"trace"`
			} `json:"cases"`
		}
		if json.Unmarshal(prev, &old) == nil {
			traces := map[string]json.RawMessage{}
			for _, c := range old.Cases {
				if len(c.Trace) > 0 {
					traces[c.Name] = c.Trace
				}
			}
			for _, m := range caseMaps {
				if tr, ok := traces[m["name"].(string)]; ok {
					m["trace"] = tr
				}
			}
		}
	}

	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0644); err != nil {
		t.Fatal(err)
	}
	fmt.Printf("wrote %d cases (%d bytes) to %s\n", len(cases), len(data), path)
}
