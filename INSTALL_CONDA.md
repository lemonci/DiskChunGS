# Conda installation (host build, no Docker)

This is an alternative to the Docker workflow documented in
[README.md](README.md). It builds DiskChunGS in a self-contained conda
environment with its own CUDA toolkit and C++ compiler, so it works on host
distributions newer than Ubuntu 20.04 (tested on Ubuntu 24.04).

## What this gets you

- Conda env `diskchungs` with CUDA 11.8 + GCC 11 + cuDNN 8.9 + cmake 3.31
- libtorch 2.3.1+cu121 in `third_party/libtorch`
- OpenCV 4.10 with CUDA in `third_party/install/opencv` (FFmpeg disabled)
- TensorRT 8.6.1 (headers + libs) in `third_party/tensorrt`
- All `bin/*` executables and `lib/*.so` libraries
- The `ros_wrapper/` is **not** built (skip ROS in this flow — RoboStack on
  Ubuntu 24.04 is fragile; build inside the Docker image if you need it).

The host needs only an NVIDIA driver (≥ 525 for CUDA 12-class libtorch, ≥ 520
works in practice). Everything else lives inside the env or the repo.

## 1. Clone with submodules

```bash
git clone --recursive https://github.com/lemonci/DiskChunGS.git
cd DiskChunGS
```

If `third_party/gaussian_splatting` fails because its upstream URL is SSH-only:

```bash
git config submodule.third_party/gaussian_splatting.url \
    https://github.com/leggedrobotics/DiskChunGS-Inria.git
git submodule update --init --recursive
```

## 2. Create the conda env

```bash
conda env create -f env_diskchungs.yml
conda activate diskchungs
# numpy 2.x breaks torch 2.3.1's ABI; pin to <2
conda install -y 'numpy<2'
pip install --extra-index-url https://download.pytorch.org/whl/cu121 \
    torch==2.3.1+cu121 torchvision==0.18.1+cu121 \
    torchmetrics==1.5.2 evo optuna optuna-dashboard \
    networkx==2.8.8 opencv-python==4.10.0.84
```

The env's `etc/conda/activate.d/zz-diskchungs.sh` is the file the conda
hooks expect: it sets `CUDA_HOME`, `Torch_DIR`, `OpenCV_DIR`, `TENSORRT_ROOT`,
and `LD_LIBRARY_PATH` (including `$CONDA_PREFIX/lib` so the binaries find
the env's CUDA / NPP / openblas at runtime) so the build and the resulting
binaries pick up the in-repo third-party trees. It hardcodes the repo
location — adjust `DISCKCHUNGS_REPO=...` at the top if you cloned elsewhere.

## 3. Download libtorch

```bash
cd third_party
wget 'https://download.pytorch.org/libtorch/cu121/libtorch-cxx11-abi-shared-with-deps-2.3.1%2Bcu121.zip' \
    -O libtorch-cu121.zip
unzip -q libtorch-cu121.zip && rm libtorch-cu121.zip
# nvrtc-builtins symlink fix (same as Dockerfile.base)
ln -sf libnvrtc-builtins-6c5639ce.so.12.1 libtorch/lib/libnvrtc-builtins.so.12.1
cd ..
```

## 4. Build OpenCV with CUDA

Clone the two upstream repos at the commits the Dockerfile pins, then run
the build script:

```bash
cd third_party
git clone https://github.com/opencv/opencv.git && (cd opencv && git checkout a03b813)
git clone https://github.com/opencv/opencv_contrib.git && (cd opencv_contrib && git checkout b236c71)
cd ..
./scripts/build_opencv.sh   # 30-60 min on 20 cores
```

The script disables FFmpeg because conda-forge ships FFmpeg 8 and OpenCV
a03b813 only supports FFmpeg ≤ 6. The datasets in the paper (Replica, TUM,
KITTI) are image sequences, so FFmpeg is not needed for the pipeline.

If you need video I/O, install `ffmpeg=6.*` in the env before building OpenCV
and re-enable `-DWITH_FFMPEG=ON` in `scripts/build_opencv.sh`.

## 5. Install TensorRT 8.6.1

The pip `tensorrt` wheel ships the runtime `.so` files but no C++ headers, so
we pull headers from the NVIDIA `.deb` packages (no login required):

```bash
pip install 'tensorrt==8.6.1.post1'

TRT=third_party/tensorrt
mkdir -p $TRT/include $TRT/lib /tmp/trt-debs && cd /tmp/trt-debs
for pkg in libnvinfer-headers-dev libnvinfer-dev libnvinfer-plugin-dev \
           libnvonnxparsers-dev libnvparsers-dev libnvinfer-headers-plugin-dev; do
    curl -sSL -O "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/${pkg}_8.6.1.6-1+cuda11.8_amd64.deb"
done
for deb in *.deb; do dpkg-deb -x "$deb" extracted/; done
cd -
find /tmp/trt-debs/extracted -name '*.h' -path '*/include/*' \
    -exec cp {} $TRT/include/ \;

# Symlink the pip-installed libs into a path CMake can find
TRT_PIP=$CONDA_PREFIX/lib/python3.10/site-packages/tensorrt_libs
cd $TRT/lib
for so in libnvinfer.so.8 libnvinfer_plugin.so.8 libnvonnxparser.so.8 \
          libnvparsers.so.8 libnvinfer_builder_resource.so.8.6.1; do
    ln -sf $TRT_PIP/$so $so
    ln -sf $so ${so%.so.*}.so
done
cd -
rm -rf /tmp/trt-debs
```

## 6. Build DiskChunGS

```bash
./scripts/build.sh
```

Produces `bin/{replica_mono,replica_rgbd,tum_mono,tum_rgbd,kitti_stereo,view_result}`
and `lib/*.so`.

## 7. Run

Same invocations as the README, but skip the docker container. Make sure the
env is active so the runtime `LD_LIBRARY_PATH` is set:

```bash
conda activate diskchungs
bin/replica_rgbd \
    third_party/ORB-SLAM3/Vocabulary/ORBvoc.txt \
    cfg/ORB_SLAM3/RGB-D/Replica/office0.yaml \
    cfg/gaussian_mapper/RGB-D/Replica/replica_rgbd.yaml \
    /path/to/Replica/office0 \
    results/replica_rgbd/office0
```

## Notes / things that bit us

- `cmake_minimum_required(VERSION 2.8)` in ORB-SLAM3's `Thirdparty/*` and the
  ORB-SLAM3 root will be refused by cmake 3.30+. `scripts/build.sh` passes
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` to keep them working.
- The original `CMakeLists.txt` hardcoded `/workspace/third_party/...` for
  `OpenCV_DIR` and the libtorch `CMAKE_PREFIX_PATH`. The conda-friendly
  variant prefers `${CMAKE_SOURCE_DIR}/third_party/...` when present and
  falls back to the Docker path otherwise — Docker builds still work.
- TensorRT is **not optional** in the source even though `CMakeLists.txt`
  treats it as such — `src/depth/mono_depth.cpp` and `include/depth/stereo_depth.h`
  include `<NvInfer.h>` unconditionally.
- `M_PIf32` (used in `viewer/imgui_viewer.cpp`) is a GNU libc extension not
  defined in conda's sysroot 2.17. Patched to `static_cast<float>(M_PI)`.
- The Ubuntu apt layout puts jsoncpp headers under `jsoncpp/json/json.h`;
  conda-forge puts them at `json/json.h`. The env activation creates a
  `$CONDA_PREFIX/include/jsoncpp/json -> ../json` symlink.
- `bin/replica_rgbd` etc. need the env active at runtime so `libORB_SLAM3.so`,
  the OpenCV and libtorch libs, and the TensorRT libs resolve via
  `LD_LIBRARY_PATH`.
