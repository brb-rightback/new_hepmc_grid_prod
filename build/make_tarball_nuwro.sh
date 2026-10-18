#!/bin/bash
# make_tarball_nuwro.sh [out.tar.gz]
# Packs the NuWro grid tarball read by common/hepmc_grid_init.sh:
#   generator.sh  nuwro/bin/  nuwro/data/  params/  nuwro_to_hepmc.cc  hepmc_text.h  VERSION
# Uses the build from build_nuwro.sh (build/nuwro), which must come from an SL7
# environment with the e26 products of global_vars.sh (see build_gibuu.sh).
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top=$(dirname "$here")
out=$(realpath -m "${1:-$here/nuwro_grid.tar.gz}")
n=$here/nuwro
[ -x "$n/bin/nuwro" ] || { echo "no NuWro build in $n (run build_nuwro.sh)"; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$top/prod_nuwro/generator.sh" "$top/prod_nuwro/nuwro_to_hepmc.cc" "$top/common/hepmc_text.h" "$stage/"
mkdir -p "$stage/nuwro"
cp -r "$n/bin" "$stage/nuwro/bin"
cp -r "$n/data" "$stage/nuwro/data"
[ -d "$n/lib" ] && cp -r "$n/lib" "$stage/nuwro/lib"
cp "$top/prod_nuwro/params/beam_BNB_numu_uboone.txt" "$stage/nuwro/data/beam/"
mkdir -p "$stage/params"
cp "$top"/prod_nuwro/params/nuwro_*.txt "$stage/params/"
{ echo "NuWro $(git -C "$n" describe --tags 2>/dev/null)"; echo "local changes: $(git -C "$n" diff --stat | tail -1)";
  echo "built: $(stat -c %y "$n/bin/nuwro")"; echo "packed: $(date -u)"; } > "$stage/VERSION"
tar -czf "$out" -C "$stage" .
ls -la "$out"
