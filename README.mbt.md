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
