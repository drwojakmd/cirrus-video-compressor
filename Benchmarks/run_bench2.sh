#!/bin/bash
# Priority run: real camera footage first (Xiph sequences), then remaining synthetic clips.
set -e
cd "$(dirname "$0")"
PY=/opt/homebrew/bin/python3
OUT=results/m1max_1080p.jsonl
LIVE="clips/live_crowd_run.mkv clips/live_park_joy.mkv clips/live_ducks_take_off.mkv"
$PY bench.py $LIVE --encoders L_svtav1_p4 L_svtav1_p6 L_svtav1_p8 L_svtav1_p10 L_x265_slow L_x265_medium L_x264_slow L_vt_hevc --out $OUT
$PY bench.py $LIVE --encoders L_svtav1_p6_8bit L_svtav1_p6_tune1 L_svtav1_p6_grain L_vp9_cpu2 --out $OUT
$PY bench.py clips/camera_person.mov clips/landscape.mov --encoders L_svtav1_p4 L_svtav1_p6 L_svtav1_p8 L_x265_slow L_x264_slow L_vt_hevc --out $OUT
$PY bench.py clips/screen.mov clips/animation.mov --encoders svtav1_p6_scm --out $OUT
echo BENCH2_DONE
