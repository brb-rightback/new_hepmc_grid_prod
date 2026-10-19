#!/bin/bash
# make_tarball_gibuu.sh [out.tar.gz]
# Packs the GiBUU grid tarball read by common/hepmc_grid_init.sh:
#   generator.sh  generator_gibuu_mix.sh  GiBUU.x  lib/  buuinput/  jobcards/  mix/
#   gibuu_to_hepmc.cc  hepmc_text.h  VERSION
# Uses the build from build_gibuu.sh (build/GiBUU). For the grid, that build must
# come from an SL7 environment (see build_gibuu.sh).
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run this script as ./make_tarball_gibuu.sh (do not source it)." >&2
  return 1
fi
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top=$(dirname "$here")
out=$(realpath -m "${1:-$here/gibuu_grid.tar.gz}")
g=$here/GiBUU
[ -x "$g/release/objects/GiBUU.x" ] || { echo "no GiBUU build in $g (run build_gibuu.sh)"; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$top/prod_gibuu/generator.sh" "$top/prod_gibuu/generator_gibuu_mix.sh" \
   "$top/prod_gibuu/gibuu_to_hepmc.cc" "$top/common/hepmc_text.h" "$stage/"
cp "$g/release/objects/GiBUU.x" "$stage/"
cp -r "$g/lib" "$stage/lib"
cp -rL "$g/buuinput" "$stage/buuinput"
# Flux: GiBUU 2025 patch 5 ships new BNB flux files (arbitrary units). To keep GiBUU,
# NuWro (prod_nuwro/params/beam_BNB_numu_uboone.txt), the channel tables (prod_gibuu/mix)
# and the POT normalisation (validation/check_production.py --flux) on the same tables,
# the MicroBooNE MCC9 tables of all four BNB flavours are installed here.
# GIBUU_BNB_FLUX_DIR=none keeps the files that come with GiBUU.
fluxdir=${GIBUU_BNB_FLUX_DIR:-$top/data/flux}
if [ "$fluxdir" != "none" ]; then
  for fl in numu numubar nue nuebar; do
    cp "$fluxdir/BNB_${fl}_uboone_mcc9.dat" "$stage/buuinput/neutrino/BNB_${fl}.dat"
    echo "installed $fluxdir/BNB_${fl}_uboone_mcc9.dat as buuinput/neutrino/BNB_${fl}.dat"
  done
fi
cp -r "$top/prod_gibuu/jobcards" "$stage/jobcards"
cp -r "$top/prod_gibuu/mix" "$stage/mix"
{ cat "$g/version.txt"; echo "patches: $(ls "$top/prod_gibuu/patches" | tr '\n' ' ')";
  echo "BNB fluxes: $fluxdir"; echo "built: $(stat -c %y "$g/release/objects/GiBUU.x")"; echo "packed: $(date -u)"; } > "$stage/VERSION"
tar -czf "$out" -C "$stage" .
ls -la "$out"
