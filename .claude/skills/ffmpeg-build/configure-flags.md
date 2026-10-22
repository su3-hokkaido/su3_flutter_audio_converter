# FFmpeg configure flags (minimal, audio-only, LGPL)

Derived from `docs/project_plan.md` §5.3 and §5.4. Platform-specific flags (`--target-os`, `--arch`,
`--cross-prefix`, `--sysroot`, `--cc`, `--extra-cflags`, ...) are added by each build script.

```
--disable-everything
--disable-programs          # no ffmpeg / ffprobe / ffplay
--disable-doc
--disable-avdevice
--disable-avfilter
--disable-swscale
--disable-network
--disable-autodetect
--disable-static
--enable-shared
--enable-small
--disable-debug

--enable-libmp3lame

--enable-protocol=file

--enable-demuxer=mp3,mov,asf,wav,aac
--enable-muxer=mp3,ipod,asf,wav,adts
--enable-decoder=mp3,mp3float,aac,wmav1,wmav2,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8
--enable-encoder=libmp3lame,aac,wmav2,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le
--enable-parser=mpegaudio,aac
```

## Notes

- Never add `--enable-gpl`, `--enable-version3` combined with GPL parts, `--enable-nonfree`, or
  `--enable-libfdk-aac`.
- Libraries produced: libavformat, libavcodec, libswresample, libavutil only.
- The muxer for m4a is `ipod` (mov family); confirm it is sufficient when testing and report if
  `mov` or `mp4` muxers are also required.
- `pcm_*` decoders/encoders are listed explicitly; add other PCM variants only after asking, since
  §5.3 says `pcm_*` for decoders and four named encoders.
- Re-verify option names against the pinned FFmpeg version's `./configure --help` before the first
  build; options change between releases.
