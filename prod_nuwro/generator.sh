#!/bin/bash
# NuWro plugin for common/hepmc_grid_init.sh (sourced from inside the tarball).
#
# Tarball layout (build/make_tarball_nuwro.sh):
#   generator.sh  nuwro/bin/  nuwro/data/  params/*.txt  nuwro_to_hepmc.cc  hepmc_text.h
#
# NuWro and the converter need ROOT + Pythia6 (the e26 builds NuWro was compiled
# against). They run in a clean environment (env -i) that sets those up from cvmfs, so
# they never mix with the uboonecode (e17) environment of the job.
#
# Config (hepmc_grid.cfg):
#   NUWRO_PARAMS            params file in params/ (seed and event counts are overridden)
#   NUWRO_TEST_EVENTS       number_of_test_events per job (cross-section/max-weight estimate)
#   NUWRO_UPS_SETUP         UPS setup script   (default: uboone mcc9 setup on cvmfs)
#   NUWRO_UPS_PRODUCTS      products to set up (default: the e26 ROOT/Pythia6 of global_vars.sh)
#   NUWRO_EXTRA_EVENTS      events generated beyond what is needed (default 0; NuWro
#                           produces exactly number_of_events)
#   NUWRO_USE_VERTEX        1 = keep NuWro's vertex (geometry mode) instead of the TPC box

GEN_NAME=nuwro

nuwro_env() {  # nuwro_env "<commands>": run in a clean ROOT/Pythia6 (e26) environment
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" \
      NUWRO_UPS_SETUP="$NUWRO_UPS_SETUP" NUWRO_UPS_PRODUCTS="$NUWRO_UPS_PRODUCTS" NUWRO_HOME="$HEPMC_WORK/nuwro" \
      bash -c 'source "$NUWRO_UPS_SETUP" > /dev/null 2>&1 || { echo "cannot source $NUWRO_UPS_SETUP"; exit 3; }
               IFS=";" read -ra prods <<< "$NUWRO_UPS_PRODUCTS"
               for p in "${prods[@]}"; do setup $p || { echo "setup $p failed"; exit 3; }; done
               export LD_LIBRARY_PATH=$NUWRO_HOME/lib:$NUWRO_HOME/bin:$PYTHIA_FQ_DIR/lib:$LD_LIBRARY_PATH
               '"$1"
}

gen_setup() {
  local v
  for v in NUWRO_PARAMS NUWRO_TEST_EVENTS; do
    [ -n "${!v}" ] || { echo "NUWRO: config variable $v not set"; return 1; }
  done
  : "${NUWRO_UPS_SETUP:=/cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh}"
  : "${NUWRO_UPS_PRODUCTS:=root v6_28_12 -q e26:p3915:prof;pythia v6_4_28x -q e26:prof}"
  : "${NUWRO_EXTRA_EVENTS:=0}"
  : "${NUWRO_USE_VERTEX:=0}"
  NUWRO_CARD=$HEPMC_WORK/params/$NUWRO_PARAMS
  [ -f "$NUWRO_CARD" ] || { echo "NUWRO: params $NUWRO_CARD not in tarball"; return 1; }
  [ -x "$HEPMC_WORK/nuwro/bin/nuwro" ] || { echo "NUWRO: nuwro/bin/nuwro missing"; return 1; }
  # NuWro finds its data relative to the binary (bin/../data) -- includes from the card
  # (@beam/..., @target/...) must exist there
  local inc
  for inc in $(grep -o "^@[^ ]*" "$NUWRO_CARD" | cut -c2-); do
    [ -f "$HEPMC_WORK/nuwro/data/$inc" ] || { echo "NUWRO: $inc (included by the card) missing from nuwro/data"; return 1; }
  done

  local out
  out=$(nuwro_env "ldd '$HEPMC_WORK/nuwro/bin/nuwro' | grep 'not found'")
  [ -z "$out" ] || { echo "NUWRO: unresolved libraries in the e26 environment: $out"; return 1; }
  nuwro_env "cd '$HEPMC_WORK' && g++ -O2 -std=c++17 \$(root-config --cflags) -o nuwro_to_hepmc nuwro_to_hepmc.cc \$(root-config --libs)" \
    || { echo "NUWRO: cannot compile nuwro_to_hepmc"; return 1; }
  echo "NUWRO: card=$NUWRO_PARAMS test_events=$NUWRO_TEST_EVENTS ($(cat "$HEPMC_WORK/VERSION" 2>/dev/null | head -1))"
  return 0
}

gen_units() {  # NuWro writes exactly number_of_events events
  echo $(( $1 + NUWRO_EXTRA_EVENTS ))
}

gen_run() {
  local dir=$1 seed=$2 nevents=$3
  cp "$NUWRO_CARD" "$dir/params.txt"
  nuwro_env "cd '$dir' && timeout '$HEPMC_TIMEOUT' '$HEPMC_WORK/nuwro/bin/nuwro' -i params.txt -o events.root \
               -p 'random_seed=$seed' -p 'number_of_events=$nevents' -p 'number_of_test_events=$NUWRO_TEST_EVENTS'" \
    > "$dir/generator.log" 2>&1
  local rc=$?
  [ "$rc" -eq 3 ] && { echo "NUWRO: environment setup failed"; return 2; }
  [ "$rc" -eq 124 ] && { echo "NUWRO: timeout"; return 1; }
  [ "$rc" -eq 0 ] || { echo "NUWRO: nuwro exited with $rc"; return 1; }
  echo "$nevents" > "$dir/requested"
  return 0
}

gen_validate() {
  local dir=$1 seed=$2
  [ -s "$dir/events.root" ] || { echo "no events.root"; return 1; }
  # the patched NuWro prints the Pythia6 seed; without it hadronization is correlated
  grep -q "Pythia6 random seed" "$dir/generator.log" || { echo "NuWro build without nuwro_grid.patch (Pythia6 not seeded)"; return 1; }
  local nreq; nreq=$(cat "$dir/requested")
  local n
  n=$(nuwro_env "root -l -b -q -e 'TFile f(\"$dir/events.root\"); TTree* t=(TTree*)f.Get(\"treeout\"); std::cout << \"NENTRIES \" << (t ? t->GetEntries() : -1) << std::endl;'" \
      | awk '/^NENTRIES/{print $2}')
  [ "$n" = "$nreq" ] || { echo "events.root has '$n' entries, requested $nreq"; return 1; }
  echo "$n"
}

gen_convert() {
  local out=$1 seed=$2; shift 2
  local f=() d opts=$HEPMC_CONVERTER_OPTS
  for d in "$@"; do f+=("$d/events.root"); done
  [ "$NUWRO_USE_VERTEX" = "1" ] && opts="$opts --use-vertex"
  nuwro_env "cd '$PWD' && '$HEPMC_WORK/nuwro_to_hepmc' -o '$out' -s '$seed' $opts ${f[*]}"
}

gen_info() {
  echo "card=$NUWRO_PARAMS test_events=$NUWRO_TEST_EVENTS"
}
