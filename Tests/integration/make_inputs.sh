#!/bin/bash
# Build realistic test inputs from the benchmark clips: the kinds of files
# people actually have (camera/screen-recorder H.264 + AAC), plus edge cases.
# Usage: make_inputs.sh OUTDIR
set -euo pipefail
cd "$(dirname "$0")/../.."
CLIPS=Benchmarks/clips
OUT=${1:-Tests/integration/inputs}
mkdir -p "$OUT"
FF="ffmpeg -v error -y -nostdin"
# speech-like audio: band-limited noise bursts, stereo-identical (dual mono, as many mics record)
SPEECH="anoisesrc=d=60:c=pink:a=0.25,highpass=f=200,lowpass=f=3800,volume='if(lt(mod(t,1.3),0.9),1,0.05)':eval=frame"
MUSIC="sine=f=220:d=60,aformat=channel_layouts=mono[a];sine=f=330:d=60[b];[a][b]amerge,aformat=channel_layouts=stereo,volume=0.3"

# 1. talking-head animation, 60 s, like an export from an animation tool: H.264 high bitrate, AAC 320k dual-mono
$FF -stream_loop 4 -i $CLIPS/talking_head.mov -f lavfi -i "$SPEECH" -t 60 -map 0:v -map 1:a -ac 2 \
    -c:v libx264 -preset fast -crf 14 -pix_fmt yuv420p -c:a aac -b:a 320k -shortest "$OUT/th_animation_1080p.mp4"
# 2. screen recording, 36 s, AAC 160k stereo
$FF -stream_loop 2 -i $CLIPS/screen.mov -f lavfi -i "$MUSIC" -t 36 -map 0:v -map 1:a \
    -c:v libx264 -preset fast -crf 16 -pix_fmt yuv420p -c:a aac -b:a 160k -shortest "$OUT/screen_1080p.mp4"
# 3. live action 1080p50 (crowd run), HEVC camera-style 10-bit, 5.1 audio
$FF -stream_loop 2 -i $CLIPS/live_crowd_run.mkv -f lavfi -i "anoisesrc=d=60:c=brown:a=0.2" -t 24 -map 0:v -map 1:a \
    -filter:a "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:v libx265 -preset fast -crf 18 -pix_fmt yuv420p10le -tag:v hvc1 \
    -x265-params log-level=error -c:a aac -b:a 384k -shortest "$OUT/live_crowd_5.1.mp4"
# 4. 4K source (upscaled landscape) for 4K→1080p targets
$FF -i $CLIPS/landscape.mov -f lavfi -i "$MUSIC" -t 12 -map 0:v -map 1:a -vf scale=3840:2160:flags=lanczos \
    -c:v libx264 -preset fast -crf 16 -pix_fmt yuv420p -c:a aac -b:a 256k -shortest "$OUT/landscape_4k.mp4"
# 5. portrait phone video, MOV
$FF -i $CLIPS/live_park_joy.mkv -f lavfi -i "$SPEECH" -t 8 -map 0:v -map 1:a -vf "transpose=1" \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$OUT/portrait_phone.mov"
# 6. variable frame rate, no audio
$FF -i $CLIPS/camera_person.mov -t 12 -vf "setpts='if(lt(N,150),PTS,PTS*1.5)'" -fps_mode vfr \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an "$OUT/vfr_noaudio.mp4"
# 7. HDR10-tagged 10-bit (synthetic signalling)
$FF -i $CLIPS/live_ducks_take_off.mkv -t 6 -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc -c:v libx265 -preset fast -crf 18 -pix_fmt yuv420p10le -tag:v hvc1 \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -x265-params "log-level=error:hdr10=1" "$OUT/hdr10.mp4"
# 8. odd dimensions + very short + MKV container + Opus audio
$FF -i $CLIPS/animation.mov -f lavfi -i "$MUSIC" -t 2.5 -map 0:v -map 1:a -vf "scale=1918:1078" \
    -c:v libx264 -preset fast -crf 16 -pix_fmt yuv420p -c:a libopus -b:a 128k -shortest "$OUT/short_odd.mkv"
ls -la "$OUT"
# 10. camera footage with burnt-in captions and a small credit line (text guard), H.264 + AAC
$FF -i $CLIPS/captions.mov -f lavfi -i "$SPEECH" -t 18 -map 0:v -map 1:a -ac 2 \
    -c:v libx264 -preset fast -crf 15 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest "$OUT/captions.mp4"
