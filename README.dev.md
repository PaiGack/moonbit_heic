当前进度：M0（工程骨架 + `safe/`）、M1（HEIF / ISOBMFF 容器）、
M2（HEVC 头解析：NAL / AnnexB / hvcC 分帧、位读取、VPS / SPS / PPS、
slice segment header）、M3（CABAC + 仅 I 帧解码）、M4（色彩转换 + PNG/JPEG
输出）与 M5（CLI + 端到端验收）均已完成。
所有字段与上游逐项对齐。M3 正自底向上
分层落地：CABAC 算术解码器（179 上下文、Table 9-4/9-46/9-47 逐条对齐）、
系数扫描表与逆变换基矩阵、反量化 / 2D 逆变换 / 35 种帧内预测（recon 层）、
残差系数语法 7.3.8.11（residual 层，真实 CABAC 码流对拍）、环路滤波内核
（loopfilter 层，整帧上游真值对拍）、CTU 级 CABAC 语法元素 7.3.8.2~7.3.8.10
（syntax 层：SAO / 帧内模式 / cu_qp_delta / cu_chroma_qp_offset / part_mode /
split·cbf 上下文与 8.4.2 MPM，真实 Go 编码器码流往返对拍）、CTU 空间状态
（geometry 层：6.5.2 MinTbAddrZs / 6.4.1 邻域可用性 / 8.6.1 qPY_PRED /
8.4.4.2.2 参考样本收集），第一次真正产出像素的单块重建链路
（reconstruct 层：把已验证的 geometry + recon + residual + CABAC 串成
「一段真实残差码流 → 一个变换块的像素」，逐样本对拍上游 reconstructPlane），
以及把它们接成整帧的 CTU quadtree/TU/PU 语法主循环（ctu 层：按 7.3.8 的
bin 顺序驱动 quadtree → CU → transformTree → transformUnit，每个变换块调
`reconstruct_block`）。`decode_i_frame` 现在对单 slice、单 tile、无 WPP 的
Main 8bit 4:2:0 I 帧真正返回 `Yuv420p8`，与上游 `*_ref.yuv` 逐像素一致；
帧级去块（8.7.2）也已接进 decode 路径：CTU 主循环记录真实的 TU/PU 边界、
每 4×4 块 QP 与 cbf/noFilter，`deblock_frame` 据此只滤真正的边缘，
`encoder_lossy_32x32.h265` 的 109 个像素变化由上游完整解码 YUV 逐字节验收；
最后一层把 SAO 语法/应用、scaling list、PCM、transform skip、transquant
bypass、cu_chroma_qp_offset 全部接进 CTU 主循环与 decode 路径，14 帧端到端
固件（含 4032×3024 大图）逐像素 / 指纹对齐上游，`decode_i_frame` 对单 slice
单 tile 无 WPP 的 Main 8bit 4:2:0 I 帧已完整交付。

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
模式真实码流往返）都与 Go 上游零差异；geometry 层的 14759 个值（36 组完整
MinTbAddrZs 表 / 6400 次邻域可用性 / 45 次 qPY_PRED / 9 组参考样本）与独立
JS 转录零差异，reconstruct 层的 17 个单块场景（luma+chroma、log2 2~4、
真实残差码流）由 MoonBit 侧用已验证内核逐样本复现上游解码器输出。整帧层把
13 个上游小 I 固件（16×16~64×64，含 quadtree 深度、4/8/16/32 TU、
cu_qp_delta、sign hiding、强帧内平滑、多 CTB 邻域）交给真实 Go 解码器
`DecodeNAL + Flush` 产出最终 planar YUV，并对其中 8 个带 `*_ref.yuv` 的
固件逐字节断言；MoonBit `decode_i_frame` 对这 13 帧逐像素 byte-exact
复现，trace 里 300 个变换块的坐标/模式/QP/cbf 由真实 `codingTreeUnit`
导出作调试 oracle。帧级去块另有一套端到端固件：真实 Go 解码器对 6 个单
slice I 帧分别产出「含去块 / 关去块」的整帧 YUV 并 hook 出去块前的真实
4×4 边界状态，其中 1 帧去块真生效（109 像素）、5 帧为 no-op 回归（4 帧带
`*_ref.yuv`）；MoonBit `decode_i_frame` 逐像素复现含去块 YUV，crosscheck
独立重算指纹、差异数与边界状态不变量。每层 golden 固件在 CI 里都有
`--check`，另有独立 JS 转录 crosscheck，手改一个字节就红。

M3 收尾这一层把交付清单里剩下的工具全部接通并端到端 byte-exact 验收：
SAO 语法（7.3.8.3，含 mergeLeft/mergeUp）与帧级应用（8.7.3，每 CTB 每分量
独立参数）、scaling list（7.4.5 派生 factors 表，8.6.3 进 dequant）、
PCM（7.3.8.7 / 8.4.4.1，pcmOffset 对齐后重启 CABAC 且保留上下文）、
transform skip、transquant bypass（cu_transquant_bypass_flag，残差直通
无缩放无变换）、cu_chroma_qp_offset。外加 1280×720 / 1920×1088 /
4032×3024 三档规模验收——Issue 要的「单张 iPhone 4032×3024 I 帧能解完不崩」
由真实 Go 解码器产出第一帧 planar YUV、MoonBit `decode_i_frame` 用 FNV-1a
checksum + 64 个探针逐样本对齐。固件共 14 帧：`sao.h265` /
`scaling_list.h265` / `pcm.h265` 带上游 `*_ref.yuv` 权威真值，
两帧 SAO 真生效（1226 / 5976 像素变化）由上游编码器生成、
`transquant_bypass_64x64` / `tskip_128x128` / `signhide_scaling_320x240`
等由真实 Go 解码器给真值；每层同样有 golden `--check` + 独立 JS
crosscheck（指纹 / FNV / 16384 个 scaling factor 值零差异）。

范围边界：接受单 slice、单 tile、无 WPP 的 Main 8bit 4:2:0 纯 I 帧，
且上述工具全部打开也照解。多 slice 拼接、tiles、WPP 仍明确返回
`DecodeError`（不伪造像素）——tiles/WPP 是 Issue「单线程（放弃 WPP/tiles
并行）」锁死的范围外；带权威 `*_ref.yuv` 的多 slice 固件全都同时开 WPP，
留作后续。畸形码流一律 `DecodeError`，不 trap。


## M4：从 YUV 到能看的图

`decode_i_frame` 吐出 `Yuv420p8` 之后，M4 把它变成 PNG / JPEG：

- `color/`：BT.601 / BT.709 / BT.2020 三套矩阵（`nclx` 的
  `matrix_coefficients` 选择）、limited / full range、4:2:0 最邻近上采样、
  PQ / HLG 的最简 SDR 映射、alpha 平面合成。整数定点，`safe/` 管尺寸。
- `image/`：MIAF 7.3.6.7 顺序——先 `clap` 裁剪，再 `irot`（0/90/180/270）、
  `imir`（水平/垂直），最后交给编码器。
- `io/png/`：自写 chunk 层，支持 RGBA8 / RGBA16（`pixi` 说 10bit 时出
  16bit 容器）、可控 DEFLATE 级别（复用 MoonBit core 的 `compress/zlib`）、
  CRC-32、以及 `colr`/`prof` 的 ICC profile 原样塞进 `iCCP`。
- `io/jpeg/`：自写 baseline 编码器，RGB→YCbCr→8×8 DCT→质量可调量化→
  标准 Huffman 表，4:4:4 无色度子采样，`0xFF` 字节填充，ICC 走 `APP2`。
  JPEG 没有 alpha，透明像素合成到白底。

```bash
moon run cmd/heic2png -- photo.heic              # 默认 8-bit PNG
moon run cmd/heic2png -- --16bit photo.heic      # 16-bit 容器
moon run cmd/heic2png -- --jpeg --quality 90 photo.heic out.jpg
```

`tools/m4_cli_selftest.mjs` 把 M3 的真实 I 帧码流包成最小 HEIC，跑通
容器 → 解码 → 色彩 → 编码全链路，并校验 PNG/JPEG 头与几何尺寸；PNG 和
JPEG 的像素另由 Pillow 外部解码验收。

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



## M5：能真用起来的命令

```bash
heic2png photo.heic                       # → photo.png
heic2png photo.heic -o out.png            # 指定输出
heic2png -f jpg -q 90 photos/             # 目录批量，默认 4 任务并发
heic2png --16bit photo.heic               # 16-bit PNG 容器
heicinfo photo.heic                       # 元信息（M1 的预演命令）
```

MoonBit 里跑同一件事用 `moon run cmd/heic2png -- ...`、`moon run
cmd/heicinfo -- ...`。退出码按 Issue 约定：**0 成功 / 1 输入不可读 /
2 不支持的 profile / 3 解码失败**。错误一律打印到 stderr，不吞异常；
`@env.exit` 是干净退出，不会甩一栈 wasm 调用栈。命令行写错、文件读不了、
输出写不了都归 1；容器或码流声明了 10bit / 4:2:2 / 4:4:4 / Main 10 /
grid / P·B 帧 / 多 slice / tiles / WPP 归 2；Main 8bit 4:2:0 I 帧解坏了归 3。

`heic2png` 的目录批量用 `moonbitlang/core/async` 的 task group +
semaphore 限并发（`-j N`，默认 4）：每个 `.heic`/`.heif` 独立出图，
`-o` 只对单输入有效，最坏退出码作为进程状态。参数表、错误分类、退出码
都在 `cmd/convert/`（`moon test` 里 248 条用例覆盖），进程胶水在
`cmd/cli/`。

## 端到端验收（`tools/e2e/`）

```bash
node tools/e2e/run.mjs --smoke            # CI 冒烟：1 张 16x16，native 单后端
node tools/e2e/run.mjs                    # 全量：5 张固件 + 4 后端耗时
node --test tools/e2e/                   # harness 自测（参考转换/PNG 解码/PSNR）
```

`tools/frame_golden.json` 里每个 case 都带**真实上游 Go 解码器**
（`DecodeNAL + Flush`, `-tags noasm`）输出的 planar YUV。`build_case.mjs`
把码流包成最小 HEIC，`run.mjs` 跑 MoonBit CLI 出 PNG，再拿一份**独立写的**
JS BT.709 limited-range YUV→RGB（`reference.mjs`，不是待测的 MoonBit
`color/` 代码）算出参考 RGBA，逐字节比 PSNR：确定性重建的帧是 `inf dB`
（完全相等），带量化噪声的 `qp_small.h265` 实测 **47.26 dB**，均高于
Issue 的 45 dB 线。报告里还带四后端 `convert()` 墙钟耗时与产物体积，
写成 `tools/e2e/report.json`。CI 只跑 `--smoke`，不碰 4032×3024。

`heif-convert` / libheif 与 iPhone 实拍 `.heic` 的比对是「外部对照」那
条硬指标：本仓库的 CI 环境没有 libheif，也没有相机原图，所以 e2e 用
**上游 Go 解码器的 planar YUV 当权威真值**做同等的逐像素 PSNR；
真机 4032×3024 的对齐在 M3 的 `frame2_golden.json` 里以 FNV-1a
checksum + 64 探针逐样本验收过，不在 CI 重跑。

## 支持什么、不支持什么（与代码实际行为对齐）

**支持**：单帧静态图、**I 帧**、**8bit**、**4:2:0**、HEVC Main /
Main Still Picture（`profile_idc` 1 / 3）、HEIF 容器、单 slice 单 tile
无 WPP、`nclx` 的 BT.601 / BT.709 / BT.2020 矩阵（含 limited / full
range、PQ / HLG 最简 SDR 映射）、`irot` / `imir` / `clap`、`auxC` alpha、
`colr`/`prof` 的 ICC 原样带进 `iCCP` / APP2、RGBA8 / RGBA16 PNG、
质量可调的 baseline JPEG（4:4:4，无子采样）。

**不支持（明确列出，代码一律拒绝而不是解出似是而非的像素）**：

| 不支持 | 拒绝位置 / 退出码 |
|---|---|
| P / B 帧、运动补偿、DPB | `decode_i_frame` → `NotISlice` / 2 |
| 10 / 12bit、Main 10、RExt | `hvcC` + SPS 双层护栏 → 2 |
| 4:2:2 / 4:4:4、4:0:0 | `hvcC` + SPS 双层护栏 → 2 |
| 编码器、HEIC 视频序列 | 无此入口 |
| 多帧 grid / 多图平铺 | `item_type == "grid"` → 2 |
| 多 slice 拼接、dependent slice、entry points | `decode_i_frame` → `NotImplemented` / 2 |
| tiles、WPP（波前并行） | `decode_i_frame` → `NotImplemented` / 2 |
| `scc` / 3D / multilayer 扩展、`cross_component_prediction` | `parse_sps` / `parse_pps` → 2 |
| EXIF 方向（只认 `irot`/`imir`，不读 Exif item） | 不处理 |
| 花式色度上采样（只有最邻近） | 固定行为 |
| 花式 HDR 色调映射（PQ/HLG 只做 1000-nit 最简映射） | 固定行为 |
| PNG 隔行 / 调色板 / JPEG 色度子采样 / 渐进 JPEG | 不产出 |
| 非 HEVC 的 HEIF（AV1 / JPEG / 未压缩） | `is_hevc` / 2 |

畸形码流一律显式 `DecodeError` / `Decode(3)`，不 trap——`heif/testdata/malformed/`
与 `hevc/malformed_test.mbt` 是这一条的回归用例。

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

## HEVC 专利提示

HEVC / H.265 受多个专利池（MPEG LA / Access Advance 等）覆盖。**本项目
不授予任何专利权利**，也不对「使用本解码器是否需要授权」作任何陈述。
上面的 MIT / Apache-2.0 只覆盖软件著作权，不覆盖标准必要专利。对外分发、
商用部署前请自行取得相应许可。

## 已知限制（性能记录）

`cmd/bench` 把同一张 64×64 I 帧 HEIC 编译进每个后端，测的是**完整
`convert()` 墙钟**（容器 → M3 → M4 → PNG），不含进程启动。以下为
`tools/e2e/run.mjs` 在 CI 同款 debian 容器、MoonBit
`0.1.20261102`、debug 构建下的一次实测（数值随机器波动，只看量级）：

| 后端 | 解码耗时 | 可执行产物体积 |
|---|---|---|
| native | ~6.3 ms/call | 2 789 472 B |
| wasm | ~5.7 ms/call | 688 797 B |
| wasm-gc | ~4.3 ms/call | 408 071 B |
| js | ~42 ms/call | 731 784 B |

- **单线程**：M3 按 Issue 的「放弃 WPP/tiles 并行」锁死，没有真线程 /
  Cond，解码是单线程；`-j` 只并行**多个独立文件**，不加速单张图。
- **SIMD 全废**：上游 7242 行汇编一行用不上，`v128` 重写推迟到 M5 之后。
- **js 后端明显慢**：数值按 JS 语义走，解码约为 native 的 6~7 倍耗时。
- **大图**：4032×3024 能解完不崩（M3 有 FNV checksum 验收），但 CI 不跑，
  e2e 冒烟只用 16×16。
- **CLI 的文件系统能力是 native / wasm only**：`@fs` / `@stdio` 在
  wasm-gc / js 目标上没有实现。`cmd/bench` 改用内嵌固件 + `println` +
  `@env.now`，因此四个后端都能编译和跑；但 `heic2png` / `heicinfo`
  这两个命令只在 native / wasm 上真正可用。这是 MoonBit 当前异步运行时的
  边界，不是解码器的边界。