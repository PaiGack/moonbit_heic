# 固件

对拍两侧共用的输入与期望输出。真固件（真实 HEIC、上游 dump）从 M1 起陆续放进来；
此处只有 M0 用来演练 `tools/parity/dump.mjs` 的最小样本。

- `empty_dump.json` —— 一个没有 NAL 的“空流”dump，用来确认两侧在退化输入上
  也给出同样形状的输出，而不是一边 `null`、一边 `[]`。
