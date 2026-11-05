# monbit_tmp

MoonBit 移植自 [gen2brain/h265](https://github.com/gen2brain/h265)，
一个纯 Go 的 HEVC 视频 / HEIC 图像编解码器。

当前进度：M0（工程骨架 + `safe/`）、M1（HEIF / ISOBMFF 容器）与
M2（HEVC 头解析：NAL / AnnexB / hvcC 分帧、位读取、VPS / SPS / PPS、
slice segment header）已完成。所有字段与上游逐项对齐。M3 正自底向上
分层落地：CABAC 算术解码器（179 上下文、Table 9-4/9-46/9-47 逐条对齐）、
系数扫描表与逆变换基矩阵、反量化 / 2D 逆变换 / 35 种帧内预测（recon 层）、
残差系数语法 7.3.8.11（residual 层，真实 CABAC 码流对拍）、环路滤波内核
（loopfilter 层，整帧上游真值对拍）、CTU 级 CABAC 语法元素 7.3.8.2~7.3.8.10
（syntax 层：SAO / 帧内模式 / cu_qp_delta / cu_chroma_qp_offset / part_mode /
split·cbf 上下文与 8.4.2 MPM，真实 Go 编码器码流往返对拍），以及
`Yuv420p8` 与 `decode_i_frame` 的接口契约。

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

一个 item 走到片层头为止长这样——M3 从这里接着解 CTU：

```moonbit
let au = @hevc.parse_access_unit(img.payload, img.hvc_c.unwrap().param_sets,
                                  img.hvc_c.unwrap().length_size, false)
println("\{au.sps.cropped_width()}x\{au.sps.cropped_height()} @ \{au.sps.bit_depth_luma}bit, \{au.slices.length()} slice")
// 每个 slice 的头已经解好，data_offset 指向它自己的 slice data
for s in au.slices {
  println("\{s.header.slice_type} poc=\{s.header.pic_order_cnt_lsb} qp=\{s.header.qp_y}")
}
```

`parse_sps` 只放行 Main（profile_idc 1，8bit 4:2:0；Main Still Picture
`profile_idc=3` 也放行）：其余一概 `UnsupportedProfile(profile_idc~,
chroma_format_idc~, bit_depth_luma~)`，把拒绝的原因说清楚，而不是静默糊过去。

M3 的这几层都用上游 Go 的真值和独立生成的 golden 码流逐 bin / 逐值对拍：
CABAC 的 8400 个 bin 与独立算术编码器写的码流逐位一致；扫描表、变换矩阵、
1D 逆变换对齐上游断言；recon 层的 222000 个值与 Go 上游未导出函数零差异；
residual 层的 122488 个值（含 118 条真实 CABAC 码流逐系数解码）、loopfilter
层的 126834 个值（含 7 个整帧场景）、syntax 层的 1739 个值（含 1260 条帧内
模式真实码流往返）都与 Go 上游零差异。每层 golden 固件在 CI 里都有
`--check`，另有独立 JS 转录 crosscheck，手改一个字节就红。

下一步：把 CTU 的 quadtree/TU/PU 语法主循环接进 `decode_i_frame`，按序
调用 syntax 层的解析、recon 层的重建 DSP、loopfilter 层的去块与 SAO，串成
重建主链路。在这之前它对合法的 I 帧返回 `DecodeError::NotImplemented`，不
伪造像素——接口形状、profile 校验、畸形码流拒绝、YUV 平面分配，以及从
SPS/PPS/片头派生并接进 decode 路径的 recon / loopfilter / syntax 参数都已
就位。

## 工程结构

每个里程碑一个包，互相之间的依赖方向是单向的：

```
safe/              Int 溢出护栏，所有移位/乘法都从这里过
heif/              HEIF / ISOBMFF 容器（M1），已实现
hevc/              NAL + 参数集 + 片层头 + AccessUnit，已实现
hevc/bitreader/    MSB-first 位读取（M2 已实现，公开读取器）
hevc/headers/      片层头的包位置（解析实现放在 hevc/slice.mbt）
hevc/cabac/        CABAC 算术解码器（M3 已实现，逐 bin 对拍）
hevc/dsp/          扫描表与逆变换基矩阵（M3 已实现）
hevc/recon/        反量化 / 2D 逆变换 / 帧内预测（M3 已实现，逐值对拍）
hevc/residual/     残差系数语法 7.3.8.11（M3 已实现，真实码流对拍）
hevc/loopfilter/   去块 8.7.2 + SAO 8.7.3（M3 已实现，整帧真值对拍）
hevc/syntax/       CTU 级 CABAC 语法元素 7.3.8.2~10（M3 已实现，真实码流往返对拍）
hevc/decode/       Yuv420p8 / decode_i_frame 契约（M3），CTU 主循环待接
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
