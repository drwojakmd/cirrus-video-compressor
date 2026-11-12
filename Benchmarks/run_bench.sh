#!/bin/bash
# Full benchmark matrix. Resumable: re-running skips finished points.
set -e
cd "$(dirname "$0")"
PY=/opt/homebrew/bin/python3
OUT=results/m1max_1080p.jsonl
CORE="svtav1_p4 svtav1_p6 svtav1_p8 svtav1_p10 x265_medium x265_slow x264_slow vt_hevc vt_h264 vp9_cpu2"
$PY bench.py clips/talking_head.mov clips/screen.mov clips/animation.mov clips/landscape.mov clips/camera_person.mov --encoders $CORE --out $OUT
$PY bench.py clips/screen.mov clips/animation.mov clips/talking_head.mov --encoders svtav1_p6_scm --out $OUT
$PY bench.py clips/landscape.mov clips/camera_person.mov --encoders svtav1_p6_grain --out $OUT
$PY bench.py clips/talking_head.mov clips/screen.mov clips/animation.mov clips/landscape.mov clips/camera_person.mov --encoders svtav1_p6_vbq --out $OUT
echo BENCH_DONE
