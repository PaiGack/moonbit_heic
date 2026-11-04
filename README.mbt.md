# monbit_tmp

MoonBit 移植自 [gen2brain/h265](https://github.com/gen2brain/h265)，
一个纯 Go 的 HEVC 视频 / HEIC 图像编解码器。

当前进度：`hevc` 包的码流解析层——NAL 单元切分与转义还原、参数集
（VPS / SPS / PPS）解析，字段与派生值逐项对齐原实现。

```moonbit
for nal in @hevc.split_annex_b(data) {
  match nal.nal_type() {
    Some(Sps) => println(@hevc.parse_sps(nal).pic_width_in_luma_samples)
    _ => ()
  }
}
```

下一步：片层头（slice header）、CTU/CABAC、帧内预测与残差重建。

## 工程结构

每个里程碑一个包，互相之间的依赖方向是单向的：

```
safe/              Int 溢出护栏，所有移位/乘法都从这里过
heif/              HEIF / ISOBMFF 容器（M1）
hevc/              NAL + 参数集，已实现
hevc/bitreader/    MSB-first 位读取（M2）
hevc/headers/      片层头（M2）
hevc/cabac/        CABAC（M3）
hevc/decode/       CTU/TU/PU 重建（M3）
color/             YUV→RGB、色域（M4）
io/png/ io/jpeg/   输出编码（M4）
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

## 对拍

`tools/parity/dump.mjs` 比较两侧的 JSON dump，报**首个差异的位置和上下文**：

```bash
node tools/parity/dump.mjs expected.json actual.json
node tools/parity/dump.mjs --first-diff expected.json actual.json
```

结构化差异给出 `$.sps.pic_width_in_luma_samples` 这样的路径；
字节差异给出首个不同字节的索引和前后 8 字节的十六进制窗口。
格式约定见 `tools/parity/README.md`。

## 开发

```bash
moon check --deny-warn
moon test
moon info && moon fmt     # 提交前跑一遍
node --test tools/parity/
```
