# 对拍工具

上游 [gen2brain/h265](https://github.com/gen2brain/h265) 用 Go 实现，端口要
逐字段对齐它。这个目录提供两件事：

1. **`dump.mjs`** —— 比较两个 JSON dump，打印**首个差异的位置 + 上下文**，
   而不是一句 "not equal"。
2. **固件格式约定** —— 两边 dump 成同一种 JSON，脚本才能比较。

## 用法

```bash
# 上游 Go 版 dump 一次
go run ./cmd/dump -in testdata/x.heic > /tmp/expected.json
# MoonBit 端口 dump 一次
moon run tools/dump -- testdata/x.heic > /tmp/actual.json
# 对拍
node tools/parity/dump.mjs /tmp/expected.json /tmp/actual.json
```

只想看第一处差异、不看全量清单：

```bash
node tools/parity/dump.mjs --first-diff /tmp/expected.json /tmp/actual.json
```

退出码：`0` 一致，`1` 有差异，`2` 输入读不了。CI 直接看退出码。

## 固件格式

同一个里程碑的 dump 必须是同一种形状。已确定的部分：

| 里程碑 | 顶层字段 | 说明 |
|---|---|---|
| M2 | `nals` | NAL 数组，每项 `{ type, layer_id, temporal_id, rbsp_hex }` |
| M2 | `vps` / `sps` / `pps` | 参数字段的平铺对象，字段名与上游结构体一致 |
| M3 | `frames` | 每帧 `{ poc, planes: { y: { hex }, u, v } }` |

像素平面用 `hex` 字符串而不是数字数组——文件小一半，且 `dump.mjs` 会把
首个不同字节的邻域打成 `[xx]` 高亮的窗口，比逐像素列表情报密度高。

## 首个差异定位

- 结构化差异：路径形如 `$.sps.pic_width_in_luma_samples` 或
  `$.nals[3].rbsp_hex`，可直接拿去 `grep`。
- 字节差异：报 `bytes[4096]`，并给出前后 8 字节的十六进制窗口，
  差异字节用 `[]` 标出。
- `reason` 区分 `value` / `length` / `missing` / `shape` / `byte`，
  一眼看出是数值错了、少了一项，还是整个子树对不上。
