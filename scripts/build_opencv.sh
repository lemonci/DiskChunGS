#!/bin/bash
# Build OpenCV 4.10 with CUDA support into third_party/install/opencv.
# Requires the disckchungs conda env to be activated.
set -e

if [ -z "$CONDA_PREFIX" ] || [ "$(basename "$CONDA_PREFIX")" != "disckchungs" ]; then
    echo "ERROR: activate the disckchungs conda env first: conda activate disckchungs" >&2
    exit 1
fi

workdir=$( cd -- "$(dirname "$0")/.." >/dev/null 2>&1 ; pwd -P )
cd "$workdir"

OPENCV_SRC="$workdir/third_party/opencv"
OPENCV_CONTRIB="$workdir/third_party/opencv_contrib"
OPENCV_BUILD="$OPENCV_SRC/build"
OPENCV_INSTALL="$workdir/third_party/install/opencv"

# Detect compute capability of the local GPU (RTX 5000 Ada -> 89). CUDA 11.8
# supports SM 8.9; "native" would also work but we pin to avoid surprises.
# Include 86 too so the binaries are usable on Ampere boxes (e.g. CI).
CUDA_ARCHES="${CUDA_ARCHES:-86;89}"

echo "Configuring OpenCV..."
cmake -B "$OPENCV_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OPENCV_INSTALL" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_CUDA_COMPILER="$CUDA_NVCC" \
    -DCMAKE_CUDA_HOST_COMPILER="$CXX" \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHES" \
    -DCUDA_TOOLKIT_ROOT_DIR="$CONDA_PREFIX" \
    -DCUDNN_INCLUDE_DIR="$CONDA_PREFIX/include" \
    -DCUDNN_LIBRARY="$CONDA_PREFIX/lib/libcudnn.so" \
    -DWITH_CUDA=ON \
    -DWITH_CUDNN=ON \
    -DWITH_CUFFT=ON \
    -DWITH_CUBLAS=ON \
    -DOPENCV_DNN_CUDA=ON \
    -DWITH_NVCUVENC=OFF \
    -DWITH_NVCUVID=OFF \
    -DBUILD_TIFF=ON -DBUILD_ZLIB=ON -DBUILD_JASPER=ON -DBUILD_CCALIB=ON \
    -DBUILD_JPEG=ON -DWITH_FFMPEG=OFF \
    -DWITH_GSTREAMER=OFF -DWITH_V4L=OFF \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
    -DOPENCV_GENERATE_PKGCONFIG=ON \
    -DOPENCV_EXTRA_MODULES_PATH="$OPENCV_CONTRIB/modules" \
    "$OPENCV_SRC"

echo "Building OpenCV (this takes 30-60 min on 20 cores)..."
cmake --build "$OPENCV_BUILD" -j"$(nproc)"
cmake --install "$OPENCV_BUILD"

echo "OpenCV installed to $OPENCV_INSTALL"
ls "$OPENCV_INSTALL/lib/" | head -5
