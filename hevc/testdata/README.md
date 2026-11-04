# hevc 固件

三个从上游 [gen2brain/h265](https://github.com/gen2brain/h265) 的
`hevc/testdata/` 拷来的码流，用来验收 M2：

| 文件 | 覆盖的点 |
|---|---|
| `1080p.h265` | 1920x1080，CTB 64，Main profile，带多个 slice |
| `ctu64_128x128.h265` | 128x128，CTB 64，PPS 带 `sign_data_hiding` |
| `tu8.h265` | 16x16，最小变换块 8x8，SAO 打开 |

都是 Main（8bit 4:2:0），也就是本端口唯一接受的 profile。10bit 的码流
（如上游的 `10bit_128x128.h265`）不在这个集合里：`parse_sps` 会以
`UnsupportedProfile` 拒掉它，那是一条单测而不是固件。
