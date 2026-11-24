#!/bin/sh
# Real data for the benchmarks (not redistributed here):
#  - OpenPIV's sample PIV recordings come with the `openpiv` Python package (openpiv/data, GPL-3.0).
#  - trackpy's `bulk_water` sample (1 µm latex spheres in water, 24 fps, 2.85 px/µm) from soft-matter/trackpy-examples,
#    encoded losslessly enough for LivePTV's video input (ProRes 422 HQ, grey) with ffmpeg.
set -e
cd "$(dirname "$0")"
mkdir -p data
if [ ! -d data/trackpy-examples ]; then
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/soft-matter/trackpy-examples.git data/trackpy-examples
  git -C data/trackpy-examples sparse-checkout set sample_data/bulk_water
fi
ffmpeg -loglevel error -y -framerate 24 -i data/trackpy-examples/sample_data/bulk_water/bulk_water_%03d.png \
  -vf format=gray,format=yuv422p10le -c:v prores_ks -profile:v 3 data/bulk_water_24fps_prores.mov
echo "data ready in $(pwd)/data"
