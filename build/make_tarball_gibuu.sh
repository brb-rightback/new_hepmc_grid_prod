#!/bin/bash
# make_tarball_gibuu.sh [out.tar.gz]
# Packs the GiBUU grid tarball read by common/hepmc_grid_init.sh:
#   generator.sh  GiBUU.x  lib/  buuinput/  jobcards/  gibuu_to_hepmc.cc  hepmc_text.h  VERSION
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
cp "$top/prod_gibuu/generator.sh" "$top/prod_gibuu/gibuu_to_hepmc.cc" "$top/common/hepmc_text.h" "$stage/"
cp "$g/release/objects/GiBUU.x" "$stage/"
cp -r "$g/lib" "$stage/lib"
cp -rL "$g/buuinput" "$stage/buuinput"
# Flux: GiBUU 2025 patch 5 ships a new, softer BNB_numu.dat (arbitrary units). To keep
# GiBUU, NuWro (prod_nuwro/params/beam_BNB_numu_uboone.txt) and the POT normalisation
# (validation/check_production.py --flux) on the same table, install it here.
# GIBUU_BNB_NUMU_FLUX=none keeps the file that comes with GiBUU.
flux=${GIBUU_BNB_NUMU_FLUX:-$top/data/flux/BNB_numu_uboone_mcc9.dat}
if [ "$flux" != "none" ]; then
  cp "$flux" "$stage/buuinput/neutrino/BNB_numu.dat"
  echo "installed $flux as buuinput/neutrino/BNB_numu.dat"
fi
cp -r "$top/prod_gibuu/jobcards" "$stage/jobcards"
{ cat "$g/version.txt"; echo "patches: $(ls "$top/prod_gibuu/patches" | tr '\n' ' ')";
  echo "BNB_numu flux: $flux"; echo "built: $(stat -c %y "$g/release/objects/GiBUU.x")"; echo "packed: $(date -u)"; } > "$stage/VERSION"
tar -czf "$out" -C "$stage" .
ls -la "$out"
