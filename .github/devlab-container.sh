#!/usr/bin/env bash
# Inside the test container (/src is the checkout): set up, then `make hip-test` for $GFX and
# the Vulkan checks on RADV. Every check lands in /src/results.txt as <check>=pass|fail.
#   GFX       the GPU's arch (gfx1151, gfx1201)
#   ROCM_SDK  empty: the image's ROCm in /opt/rocm. Else a version spec (e.g. "==10.2.*"):
#             AMD's ROCm SDK from pip (rocm[libraries,devel,device-$GFX]) from SDK_INDEX
#             (plus SDK_EXTRA, extra index URLs separated by spaces), for a release with no
#             image or apt repository.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
# make hip-test traps kernels on purpose; ROCr would pipe a GPU core dump to the host's
# core_pattern handler, which the container does not have ("GPU coredump: execvp failed").
export HSA_DISABLE_COREDUMP_ON_EXCEPTION=1
git config --global --add safe.directory '*'
result() { echo "$1=$2" >> /src/results.txt; }

apt-get update -qq && apt-get install -y -qq build-essential git python3 python3-venv \
  libvulkan-dev glslc mesa-vulkan-drivers > /dev/null || { result setup fail; exit 1; }
if [ -n "${ROCM_SDK:-}" ]; then
  extra=(); for e in ${SDK_EXTRA:-}; do extra+=(--extra-index-url "$e"); done
  python3 -m venv /r && PIP_CONFIG_FILE=/dev/null /r/bin/pip install -q --pre --index-url "$SDK_INDEX" "${extra[@]}" \
    "rocm[libraries,devel,device-$GFX]$ROCM_SDK" || { result setup fail; exit 1; }
  /r/bin/rocm-sdk init || { result setup fail; exit 1; }
  ROCM_HOME=$(/r/bin/rocm-sdk path --root)
  export PATH=$(/r/bin/rocm-sdk path --bin):$PATH LD_LIBRARY_PATH=$ROCM_HOME/lib:${LD_LIBRARY_PATH:-}
  echo "rocm $(/r/bin/python -c 'import importlib.metadata as m; print(m.version("rocm"))')" > /src/rocm-sdk.txt
  cat /src/rocm-sdk.txt
else
  ROCM_HOME=/opt/rocm
  # the WMMA kernels need rocWMMA's headers; images ship them or the apt package does
  [ -f $ROCM_HOME/include/rocwmma/rocwmma.hpp ] || apt-get install -y -qq rocwmma-dev > /dev/null ||
    echo "no rocwmma-dev package in this image's apt sources"
fi
[ -f "$ROCM_HOME/include/rocwmma/rocwmma.hpp" ] && echo "rocWMMA: $ROCM_HOME/include/rocwmma" ||
  echo "rocWMMA headers missing under $ROCM_HOME/include"
result setup pass

"$ROCM_HOME/bin/rocminfo" > /tmp/rocminfo.txt 2>&1 || true
awk '$1 == "Name:" && $2 ~ /^gfx[0-9a-f]+$/ && $2 != "gfx000" {print $2}' /tmp/rocminfo.txt | sort -u | tr '\n' ' ' | sed 's/ $//' > /src/arch.txt || true
"$ROCM_HOME/bin/hipconfig" --version > /src/hip.txt 2>/dev/null || true
echo "arch $(cat /src/arch.txt), HIP $(cat /src/hip.txt)"
if make -C c hip-test HIP=1 HIP_ARCH="$GFX" ROCM_HOME="$ROCM_HOME"; then result hip-test pass; else result hip-test fail; fi

# The real GPU through RADV, not Lavapipe (the suites default to the CPU device). Mesa only: no ROCm.
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
echo "mesa-vulkan-drivers $(dpkg-query -W -f='${Version}' mesa-vulkan-drivers)"
RESULTS=/src/results.txt LOGS=/src/vk-logs bash /src/.github/devlab-vk-checks.sh
chown -R "$(stat -c %u:%g /src)" /src
