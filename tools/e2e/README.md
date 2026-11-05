# M5 端到端验收

把上游 Go 解码器的真实 I 帧码流包成最小 HEIC，跑 MoonBit CLI 出 PNG，
再和**独立写的** JS BT.709 参考逐字节算 PSNR；顺带测四后端耗时和产物体积。

```bash
node tools/e2e/run.mjs --smoke      # CI 冒烟：1 张 16x16，单后端（有 C 编译器用 native，否则 wasm）
node tools/e2e/run.mjs              # 全量：5 张固件 + 最多 4 后端（无 C 编译器时 3 个）
node --test tools/e2e/             # harness 自测
```

## 文件

| 文件 | 作用 |
|---|---|
| `run.mjs` | 验收主体：PSNR、退出码矩阵、四后端耗时、JSON 报告 |
| `reference.mjs` | 独立 BT.709 limited-range YUV→RGB + 纯 JS PNG 解码 + PSNR |
| `run.test.mjs` | 钉住参考转换 / PNG 解码 / PSNR 本身正确 |
| `build_case.mjs` | 把 `frame_golden.json` 的码流包成最小 HEIC |
| `gen_bench_fixture.mjs` | 把 64×64 固件编进 `cmd/bench/fixture.mbt`（四后端通用） |
| `REPORT.md` | 一次全量实测的 PSNR / 耗时 / 体积记录 |
| `report.json` | `run.mjs` 生成的机器可读报告（`.gitignore` 忽略） |

## 为什么 PSNR 有 `inf`

确定性重建的帧与独立参考**逐字节相等**，MSE=0，PSNR 是 `+∞`。带量化
噪声的 `qp_small.h265` 才是有限值（实测 47.26 dB）。两者都高于 Issue 的
45 dB 线。`run.mjs` 对 `p >= 45` 断言。

## 与 libheif / iPhone 实拍的关系

Issue 的「外部对照」要求与 `heif-convert` / libheif 比 PSNR，并用 iPhone
实拍验收。CI 容器里没有 libheif，也没有相机原图，因此这里以
`tools/frame_golden.json` 里**上游 Go 解码器输出的 planar YUV 为权威真值**
做等价的逐像素对照；4032×3024 大图的对齐在 M3 的 `frame2_golden.json`
里以 FNV-1a checksum + 64 探针逐样本验收过。这两条不互相替代：前者管
「颜色/编码器有没有歪」，后者管「大图解不解得完」。

## 后端边界

`@fs` / `@stdio` 只在 native / wasm 上实现，所以 `heic2png` / `heicinfo`
两个命令只在 native / wasm 真能读文件。`cmd/bench` 用内嵌固件 +
`println` + `@env.now`，四个后端（native / wasm / wasm-gc / js）都能编译
并跑出耗时，这是性能记录的数据来源。native 后端还需要系统里有 C 编译器；
`run.mjs` 会检测，缺失时冒烟自动改用 wasm（全量报告则跳过 native），这样
在 `debian:stable-slim` 这类精简镜像里也能跑，不必为冒烟装整套工具链。
