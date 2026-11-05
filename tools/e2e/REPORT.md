# 一次全量 e2e 实测（2026-11-05）

环境：debian 容器，MoonBit `0.1.20261102`，debug 构建，`node v26.13.0`。
命令：`node tools/e2e/run.mjs`（非 `--smoke`）。数值随机器波动，只看量级。

## PSNR（CLI 输出 PNG vs 独立 JS BT.709 参考）

| 固件 | 尺寸 | PSNR |
|---|---|---|
| `angular_grad.h265` | 16×16 | `inf` dB（逐字节相等） |
| `grad64.h265` | 64×64 | `inf` dB |
| `ramp64.h265` | 64×64 | `inf` dB |
| `qp_small.h265` | 64×64 | **47.26 dB** |
| `signhide.h265` | 16×16 | `inf` dB |

全部 ≥ 45 dB（Issue 验收线）。`inf` 表示确定性重建与独立参考完全一致，
不是「没测出来」。

## 四后端解码耗时（完整 `convert()`，64×64 I 帧）

| 后端 | 耗时 | 产物体积 |
|---|---|---|
| native | ~6.3 ms/call | 2 789 472 B |
| wasm | ~5.7 ms/call | 688 797 B |
| wasm-gc | ~4.3 ms/call | 408 071 B |
| js | ~42.0 ms/call | 731 784 B |

不含进程启动；PNG 产物均为 159 B（纯色帧）。js 后端约 6~7 倍于 native。

## 退出码矩阵

| 场景 | 期望 | 实测 |
|---|---|---|
| 正常出图 | 0 | 0 |
| 输入不存在 | 1 | 1 |
| 10bit profile | 2 | 2 |
| grid | 2 | 2 |
| 4:2:2 | 2 | 2 |
| 截断码流 | 3 | 3 |
| 错误命令行 | 1 | 1 |
