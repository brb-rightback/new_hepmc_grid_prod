#!/bin/bash
#
# Build the latest NuWro release (tag NuWro_25_11_1 = master HEAD as of Oct 2026).
# Note: BuildEventGenerators checks out "tags/nuwro_25.11.1", which does not exist;
# the tags are "nuwro_25.11" and "NuWro_25_11_1".
#
# Applies ../prod_nuwro/patches/nuwro_grid.patch (Pythia6 seeding + multinomial
# channel counts, needed when NuWro runs as many small grid jobs; see that file).
# Set NUWRO_NO_PATCH=1 to build the unmodified release.
#
# NuWro needs ROOT + Pythia6 from global_vars.sh (e26). For the grid, build in an SL7
# environment (see build_gibuu.sh); on the worker node NuWro is run in a clean
# environment that sets up the same e26 products from cvmfs.

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run this script as ./build_nuwro.sh (do not source it)." >&2
  return 1
fi
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE=$(pwd)
# Load the UPS environment BEFORE set -e: global_vars.sh runs many UPS setups and
# some return a non-zero status without anything being wrong.
if [ -z "$SKIP_GLOBAL_VARS" ]; then source global_vars.sh; fi
for t in g++ make git root-config; do
  command -v "$t" > /dev/null || { echo "ERROR: $t not found (environment from global_vars.sh incomplete?)" >&2; exit 1; }
done
[ -n "$PYTHIA_FQ_DIR" ] || { echo "ERROR: Pythia6 (PYTHIA_FQ_DIR) not set up" >&2; exit 1; }
echo "Using ROOT $(root-config --version), Pythia6 in $PYTHIA_FQ_DIR"
set -e

NUWRO_TAG=${NUWRO_TAG:-NuWro_25_11_1}

[ -d nuwro ] || git clone https://github.com/NuWro/nuwro.git nuwro
cd nuwro
git fetch --tags -q
git checkout -q -- .   # drop a previously applied patch (otherwise the checkout can fail)
git checkout -q "tags/${NUWRO_TAG}"

if [ "${NUWRO_NO_PATCH:-0}" != "1" ]; then
  git apply "$HERE/../prod_nuwro/patches/nuwro_grid.patch"
  echo "Applied nuwro_grid.patch"
fi

cp "$HERE/../data/MicroBooNEGeometry.root" "$HERE/../data/MicroBooNE.txt" data/target/
cp "$HERE/../prod_nuwro/params/beam_BNB_numu_uboone.txt" data/beam/

export PATH=$PATH:$ROOTSYS/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$ROOTSYS/lib
export PYTHIA6=${PYTHIA_FQ_DIR}/lib
export LIBRARY_PATH=${LIBRARY_PATH}:${PYTHIA6}
make -j"${NJOBS:-1}"   # serial by default, as in BuildEventGenerators (ROOT dictionary rules)

echo "Built $(pwd)/bin/nuwro ($(git describe --tags))"
