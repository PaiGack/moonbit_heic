# monbit_h256

MoonBit 移植自 [gen2brain/h265](https://github.com/gen2brain/h265)，
一个纯 Go 的 HEVC 视频 / HEIC 图像编解码器。

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
hevc/loopfilter/   去块 8.7.2 + SAO 8.7.3（M3 已实现，均已接进 decode 路径）
hevc/syntax/       CTU 级 CABAC 语法元素 7.3.8.2~10（M3 已实现，真实码流往返对拍）
hevc/geometry/     CTU 空间状态 6.5.2/6.4.1/8.6.1/8.4.4.2.2（M3 已实现，逐值对拍）
hevc/reconstruct/  单块重建链路：残差码流→像素（M3 已实现，含 scaling/TS/bypass）
hevc/ctu/          CTU quadtree/TU/PU 语法主循环（M3 已实现，含 SAO/PCM/bypass 语法）
hevc/decode/       Yuv420p8 / decode_i_frame：整帧解码入口（M3 已接通全工具子集）
color/             YUV→RGB、色域、transfer、alpha（M4 已实现）
image/             irot/imir/clap 与 render 编排（M4 已实现）
io/png/            PNG 8/16bit 编码、zlib、iCCP（M4 已实现）
io/jpeg/           baseline JPEG、质量可调、APP2 ICC（M4 已实现）
cmd/convert/       M5 纯逻辑：CLI 参数、错误分类、完整转码管线
cmd/cli/           M5 进程胶水：文件/目录读写、批量并发、退出码
cmd/bench/         四后端解码耗时驱动（内嵌固件，无 fs/stdio 依赖）
cmd/heicinfo/      CLI：容器侦察（M1）
cmd/heic2png/      CLI：M1→M3→M4 端到端出 PNG/JPEG（M5 已接通）
tools/parity/      对拍脚本 + 固件
tools/e2e/         M5 端到端验收：PSNR 报告、耗时曲线、CI 冒烟
tools/build_m4_heic.mjs / m4_cli_selftest.mjs   M4 端到端自检
```

`preferred_target` 在 `moon.mod` 里设为 `wasm`——浏览器里解图是这个项目
最有说服力的叙事。


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

## 开发

```bash
moon check --deny-warn
moon test
moon info && moon fmt     # 提交前跑一遍
node --test tools/parity/
```

## 版权声明（MIT）

本工程移植自 [`gen2brain/h265`](https://github.com/gen2brain/h265) 的 Go 实现，它本身是
[`roticv/rust_h265`](https://github.com/roticv/rust_h265) 的 Go 移植。上游按
**MIT License** 发布，

上游完整 LICENSE 见 <https://github.com/gen2brain/h265/blob/master/LICENSE>。
本仓库自身代码采用 Apache-2.0（见 `LICENSE`），但与移植部分一起分发时
上述 MIT 声明一并生效。
