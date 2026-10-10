# Independently generated HDR carrier

`black-hlg.mov` was generated from mathematical constant pixel values on 2026-10-10. It contains no source image, recording, third-party footage, audio, or resource from Vivid. No Vivid asset was copied or re-encoded.

Generation command (run from the project folder, with FFmpeg and libx265 installed):

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi \
  -i 'nullsrc=s=64x64:r=2:d=1,format=yuv420p10le,geq=lum=64:cb=512:cr=512' \
  -an -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_range tv -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params 'log-level=error:pools=1:frame-threads=1:repeat-headers=1:lossless=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc' \
  -movflags +faststart \
  Sources/DisplayActivation/Resources/black-hlg.mov
```

Verified metadata:

- HEVC Main 10, `hvc1` container tag, 64 × 64 pixels.
- 10-bit 4:2:0, limited range, BT.2020 primaries and nonconstant-luminance matrix.
- HLG transfer function (`arib-std-b67`).
- Two frames, two frames per second, one second duration; no audio.
- 5,506 bytes.
- SHA-256: `ac81874af28e7c227261f59f94f9efb9314d808f8fc1eeff8bccc762287720c2`.
- Decoded first frame is exactly limited-range black: all 4,096 luma samples are 64 and all 2,048 chroma samples are 512.

`black-hlg-metadata.json` contains the saved FFprobe output. HDRCarrier loads the sample into an AVPlayer that remains muted with rate zero. It does not call play or seek, loop the sample, run a render timer, or capture the screen. Its eight-second preparation timeout and 1.5-second settling delay are one-shot control timers.

Loading readiness and valid HDR metadata do not establish physical brightness gain. The enclosing app must inspect live EDR headroom and verify visible results and restoration.
