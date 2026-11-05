# 固件

对拍两侧共用的输入与期望输出。

- `empty_dump.json` —— 一个没有 NAL 的“空流”dump，用来确认两侧在退化输入上
  也给出同样形状的输出，而不是一边 `null`、一边 `[]`。
- `hevc/` —— M2 的码流固件，见下面「M2 数据集」。
- `heic/expected_<name>.heic.json` —— M1 容器层的上游 dump。输入在
  `heif/testdata/<name>.heic`，dump 由上游 Go 实现
  （`gen2brain/h265` 的 `heic/dump_test.go`）产出，MoonBit 侧由
  `heif/parity_test.mbt` 生成同形状的文本，`tools/parity/dump.mjs` 比较两者。

## M1 数据集

输入文件都是从上游 `heic/testdata/` 拷来的，或者用上游编码器现造的最小样本：

| 文件 | 覆盖的点 |
|---|---|
| `basic.heic` | 单 item、`hvcC`/`colr`/`ispe`/`pixi`、8bit 4:2:0 |
| `alpha.heic` | `auxl` + `auxC` 的 alpha 辅图 |
| `thumb.heic` | `thmb` 缩略图，以及缩略图自己的 `clap` |
| `chroma422.heic` / `chroma444.heic` | 4:2:2 / 4:4:4 |
| `deep10.heic` | Main 10，10bit |
| `lossless.heic` | PCM 编码，`colr` 只写 matrix |
| `grid.heic` | `grid` 派生图 + 4 个 `dimg` 平铺块 |
| `enc422.heic` / `enc444.heic` | 上游编码器现造 |
| `minimal.heic` | 手搓的最小合法 HEIC，几百字节，便于人读十六进制 |
| `malformed/*.heic` | 畸形与截断输入，两侧都必须报 `invalid file` 且不 trap |

`malformed/` 里没有期望 dump：两侧的 `primary_image` 断言都是“返回 `Err`”，
比较错误字符串的价值不大，单测直接看 `is Err(_)`。

## 怎么刷新

```bash
# 上游
DUMP_DIR=heif/testdata go test ./heic -run TestDump -v > /tmp/up.txt
# MoonBit
moon test -p PaiGack/heic/heif
# 比较
for f in _build/actual_*.heic.json; do
  n=$(basename "$f" .json); n=${n#actual_}
  node tools/parity/dump.mjs tools/fixtures/heic/expected_$n.json "$f"
done
```

## M2 数据集

M2 解的是 HEVC 码流本身，输入是 `.h265` 而不是 `.heic`。三个验收码流放在
`hevc/testdata/`，字节也原样编译进 `hevc/fixtures_test.mbt`，所以头解析的
测试不需要文件系统（和 M1 的固件一样）：

| 文件 | 覆盖的点 |
|---|---|
| `1080p.h265` | 1920x1088（crop 到 1080）、CTB 64、10 个 P 帧 |
| `ctu64_128x128.h265` | 128x128、CTB 64、`sign_data_hiding`、IDR + P 两片 |
| `tu8.h265` | 16x16、最小变换块 8x8、带 prefix SEI |

三个都是 Main（8bit 4:2:0）。10bit 的 `10bit_128x128.h265` 不在集合里：
`parse_sps` 以 `UnsupportedProfile(2, 1, 10)` 拒掉它，那是一条单测而不是固件。

这一层没有 JSON dump 要对拍——固件本身就是上游的字节，测试断言的是从这些
字节解出来的字段值，值取自上游 `hevc/headers_test.go`、`nal_test.go`、
`getbits_test.go` 的期望。
