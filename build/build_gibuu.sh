#!/bin/bash
#
# Build the latest GiBUU release (release2025; hepforge currently serves patch 5).
#
# Default: ROOT-free build for grid use. NuHepMC output (EventFormat=7) does not need
# ROOT, and a ROOT-free binary does not clash with the uboonecode (e17) environment
# on the worker node. The gfortran runtime libraries are copied next to the binary
# (GiBUU/lib) so make_tarball_gibuu.sh can ship them.
#
#   WITH_ROOT=1 ./build_gibuu.sh   additionally builds RootTuple + ROOT output
#                                  (as in BuildEventGenerators, for NUISANCE use)
#
# To run on the grid the binary must be built in an SL7 environment, e.g. on a
# uboone gpvm:
#   apptainer shell -B /cvmfs,/exp,/pnfs /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest
#   source build/global_vars.sh && cd build && ./build_gibuu.sh

set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ -z "$SKIP_GLOBAL_VARS" ]; then source global_vars.sh; fi

URL="https://gibuu.hepforge.org/downloads?f="
mkdir -p GiBUU && cd GiBUU

for f in release2025.tar.gz buuinput2025.tar.gz; do
  [ -f "$f" ] || wget -q --content-disposition "${URL}${f}" -O "$f"
done
wget -q "${URL}version.txt" -O version.txt
wget -q "${URL}sha1sum.txt" -O sha1sum.txt
echo "GiBUU version: $(cat version.txt)"
grep -E " (release2025|buuinput2025)\.tar\.gz$" sha1sum.txt | sha1sum -c -

rm -rf release2025 buuinput2025 release buuinput
tar -xzf release2025.tar.gz
tar -xzf buuinput2025.tar.gz
ln -sfn release2025 release
ln -sfn buuinput2025 buuinput

# local patches (see the header of each file)
for p in ../../prod_gibuu/patches/*.patch; do
  [ -f "$p" ] || continue
  (cd release2025 && git apply -p1 "$(cd .. && realpath "$p")")
  echo "Applied $(basename "$p")"
done

if [ "${WITH_ROOT:-0}" = "1" ]; then
  [ -f libraries2025_RootTuple.tar.gz ] || \
    wget -q --content-disposition "${URL}libraries2025_RootTuple.tar.gz" -O libraries2025_RootTuple.tar.gz
  tar -xzf libraries2025_RootTuple.tar.gz
  sed -i 's/-std=c++11/-std=c++17/g' libraries/RootTuple/RootTuple-master/src/CMakeLists.txt
  mkdir -p rt_build && (cd rt_build && cmake -DCMAKE_INSTALL_PREFIX=./ ../libraries/RootTuple/RootTuple-master/ && make && make install)
  cp rt_build/lib/libRootTuple.a release/objects/LIB/lib/libRootTuple.100.a
  (cd release && make buildRootTuple_POS && make withROOT=1)
else
  (cd release && make -j"${NJOBS:-4}")
fi

# ship the gfortran runtime with the binary (the grid node may not have gcc 12's)
mkdir -p lib
for l in libgfortran.so.5 libquadmath.so.0; do
  src=$(gfortran -print-file-name=$l)
  [ -f "$src" ] && cp -L "$src" lib/
done

echo "Built $(pwd)/release/objects/GiBUU.x"
LD_LIBRARY_PATH=$(pwd)/lib ldd release/objects/GiBUU.x
