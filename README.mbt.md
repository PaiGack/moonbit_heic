# monbit_tmp

MoonBit 移植自 [gen2brain/h265](https://github.com/gen2brain/h265)，
一个纯 Go 的 HEVC 视频 / HEIC 图像编解码器。

当前进度：M0（工程骨架 + `safe/`）与 M1（HEIF / ISOBMFF 容器）已完成，
`hevc` 包的 NAL 与参数集（VPS / SPS / PPS）解析已就位。所有字段与上游逐项对齐。

M1 只搬字节，不解码：给它一个 iPhone `.heic`，它告诉你「主图是哪个 item、
载荷在文件哪个偏移、多长、编码参数是什么」。

```moonbit
let heic = @heif.parse(data).unwrap()
let img = heic.primary_image().unwrap()
println("\{img.width}x\{img.height} @ \{img.bit_depth}bit")
// 载荷是切出来的字节，不是整份文件
let payload = heic.item_payload(img.id).unwrap()
```

命令行里看同一件事：

```bash
moon run cmd/heicinfo -- photo.heic
# photo.heic: 4032x3024 | hvc1 @ HEVC Main Still Picture 8bit 4:2:0 | BT.709 | payload 2.1MB
```

下一步：片层头（slice header）、CTU/CABAC、帧内预测与残差重建。

## 工程结构

每个里程碑一个包，互相之间的依赖方向是单向的：

```
safe/              Int 溢出护栏，所有移位/乘法都从这里过
heif/              HEIF / ISOBMFF 容器（M1），已实现
hevc/              NAL + 参数集，已实现
hevc/bitreader/    MSB-first 位读取（M2）
hevc/headers/      片层头（M2）
hevc/cabac/        CABAC（M3）
hevc/decode/       CTU/TU/PU 重建（M3）
color/             YUV→RGB、色域（M4）
io/png/ io/jpeg/   输出编码（M4）
cmd/heicinfo/      CLI：容器侦察（M1）
cmd/heic2png/      CLI（M5）
tools/parity/      对拍脚本 + 固件
```

`preferred_target` 在 `moon.mod` 里设为 `wasm`——浏览器里解图是这个项目
最有说服力的叙事。

## 为什么要 `safe/`

上游 Go 的 `int` 是 64 位，MoonBit 的 `Int` 是 32 位。段代码里
`width * height * 3 / 2`、`1 << bits`、`(a + b - 1) / b` 这类表达式在 Go 里
永远成立，搬过来就会静默回绕：

```moonbit
100000 * 100000  // 1410065408，期望 10000000000
1 << 31          // -2147483648，期望一个正的掩码
```

所以凡是可能越界的中间量都显式走 `Int64`，越界时抛 `@safe.Overflow`
而不是继续算。`safe/safe_test.mbt` 里每个反例都是一条护栏。

## 容器层读到了什么

`heif` 走一遍 box 树就停手：`ftyp` / `meta` / `hdlr` / `pitm` / `iinf`+`infe` /
`iloc` / `iprp`(`ipco`+`ipma`) / `iref` / `idat`，`mdat` 只记偏移。

- **属性关联**：`ipma` 里的索引被解成每个 item 的属性集，重点读
  `hvcC`（含参数字节）、`ispe`、`pixi`、`colr`/`nclx`、`irot`/`imir`、`clap`、`auxC`。
  有 **essential** 关联指向本端不认识的属性时，该 item 标为 unsupported
  而不是装作能解。
- **主图选择**：`pitm` 说了算。缩略图靠 `thmb` 关系单独取
  （`thumbnail_of`），alpha 靠 `auxl` + `auxC` 的 URN 认
  （`alpha_of`），派生图靠 `grid` 的 `dimg` 关系找平铺块。
- **尺寸**：`ispe` 之外还有 `clap` 干净光圈，落在色度网格上才生效；
  `crop_rect` 的四个分母都先查过正负再除，畸形输入返回 `None` 而不是 trap。

## 对拍

`tools/parity/dump.mjs` 比较两侧的 JSON dump，报**首个差异的位置和上下文**：

```bash
node tools/parity/dump.mjs expected.json actual.json
node tools/parity/dump.mjs --first-diff expected.json actual.json
```

结构化差异给出 `$.sps.pic_width_in_luma_samples` 这样的路径；
字节差异给出首个不同字节的索引和前后 8 字节的十六进制窗口。
格式约定见 `tools/parity/README.md`。

M1 的固件在 `tools/fixtures/heic/`：12 个样本（含 grid、10bit、4:2:2/4:4:4、
alpha、缩略图，以及一个手搓的几百字节最小合法文件）的容器 dump 与上游 Go
逐字段一致，`moon test` 里直接比字符串。畸形与截断输入在
`heif/testdata/malformed/`，两侧统一报 `invalid file` 且都不 trap。

## 开发

```bash
moon check --deny-warn
moon test
moon info && moon fmt     # 提交前跑一遍
node --test tools/parity/
```
