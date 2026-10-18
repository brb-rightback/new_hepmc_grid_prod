#!/bin/bash
# GiBUU plugin for common/hepmc_grid_init.sh (sourced from inside the tarball).
#
# Tarball layout (build/make_tarball_gibuu.sh):
#   generator.sh  GiBUU.x  lib/  buuinput/  jobcards/*.job  gibuu_to_hepmc.cc  hepmc_text.h
#
# Config (hepmc_grid.cfg):
#   GIBUU_JOBCARD           job card in jobcards/ (SEED, runs, path_to_input are overwritten)
#   GIBUU_EQUALWEIGHTS_MAX  must match the job card and be identical for the whole sample
#   GIBUU_NUM_ENSEMBLES     must match the job card and be identical for the whole sample
#   GIBUU_A                 target mass number (expected weight = Max/(A*numEnsembles))
#   GIBUU_EVENTS_PER_RUN    measured accepted events per run for this card (Poisson mean)
#   GIBUU_Z                 safety margin in Poisson sigmas for the first attempt (default 2,
#                           ~98% of jobs need a single attempt)

GEN_NAME=gibuu

gen_setup() {
  local v
  for v in GIBUU_JOBCARD GIBUU_EQUALWEIGHTS_MAX GIBUU_NUM_ENSEMBLES GIBUU_A GIBUU_EVENTS_PER_RUN; do
    [ -n "${!v}" ] || { echo "GIBUU: config variable $v not set"; return 1; }
  done
  : "${GIBUU_Z:=2}"
  GIBUU_CARD=$HEPMC_WORK/jobcards/$GIBUU_JOBCARD
  [ -f "$GIBUU_CARD" ] || { echo "GIBUU: job card $GIBUU_CARD not in tarball"; return 1; }
  [ -x "$HEPMC_WORK/GiBUU.x" ] || { echo "GIBUU: GiBUU.x missing"; return 1; }
  [ -d "$HEPMC_WORK/buuinput" ] || { echo "GIBUU: buuinput missing"; return 1; }

  # the card must agree with the config, otherwise the weight check below is meaningless
  grep -Eq "^\s*equalWeights_Mode\s*=\s*2\b" "$GIBUU_CARD" || { echo "GIBUU: card is not in equalWeights_Mode=2"; return 1; }
  grep -Eq "^\s*equalWeights_Max\s*=\s*${GIBUU_EQUALWEIGHTS_MAX}\b" "$GIBUU_CARD" || { echo "GIBUU: equalWeights_Max in card != $GIBUU_EQUALWEIGHTS_MAX"; return 1; }
  grep -Eq "^\s*numEnsembles\s*=\s*${GIBUU_NUM_ENSEMBLES}\b" "$GIBUU_CARD" || { echo "GIBUU: numEnsembles in card != $GIBUU_NUM_ENSEMBLES"; return 1; }
  grep -Eq "^\s*A\s*=\s*${GIBUU_A}\b" "$GIBUU_CARD" || { echo "GIBUU: A in card != $GIBUU_A"; return 1; }

  # GiBUU must not see the larsoft libraries; it only needs the shipped gfortran runtime
  local missing
  missing=$(env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$HEPMC_WORK/lib" ldd "$HEPMC_WORK/GiBUU.x" | grep "not found")
  [ -z "$missing" ] || { echo "GIBUU: GiBUU.x has unresolved libraries: $missing"; return 1; }

  ( cd "$HEPMC_WORK" && g++ -O2 -std=c++11 -o gibuu_to_hepmc gibuu_to_hepmc.cc ) \
    || { echo "GIBUU: cannot compile gibuu_to_hepmc"; return 1; }

  GIBUU_EXPECTED_W=$(awk -v m="$GIBUU_EQUALWEIGHTS_MAX" -v a="$GIBUU_A" -v n="$GIBUU_NUM_ENSEMBLES" \
                       'BEGIN{printf "%.15g", m/(a*n)}')
  echo "GIBUU: card=$GIBUU_JOBCARD max=$GIBUU_EQUALWEIGHTS_MAX numEnsembles=$GIBUU_NUM_ENSEMBLES expected weight=$GIBUU_EXPECTED_W"
  return 0
}

# Number of runs for this attempt. First attempt: GIBUU_Z sigma margin on the configured
# yield. Retries: 3 sigma, and the smaller of the configured and the observed yield.
gen_units() {
  local need=$1 attempt=$2 nev=$3 nunits=$4
  local rate=$GIBUU_EVENTS_PER_RUN z=$GIBUU_Z
  if [ "$attempt" -gt 0 ]; then
    z=3
    if [ "$nunits" -gt 0 ]; then
      rate=$(awk -v r="$rate" -v e="$nev" -v u="$nunits" 'BEGIN{o=e/u; if (o>0 && o<r) r=o; print r}')
    fi
  fi
  hepmc_poisson_units "$need" "$rate" "$z"
}

gen_run() {
  local dir=$1 seed=$2 nruns=$3
  sed -e "s|^\(\s*SEED\s*=\s*\)[-0-9]*|\1$seed|" \
      -e "s|^\(\s*num_runs_SameEnergy\s*=\s*\)[0-9]*|\1$nruns|" \
      -e "s|^\(\s*path_to_input\s*=\s*\)'[^']*'|\1'$HEPMC_WORK/buuinput'|" \
      "$GIBUU_CARD" > "$dir/job.job"
  grep -Eq "^\s*SEED\s*=\s*$seed\b" "$dir/job.job" \
    && grep -Eq "^\s*num_runs_SameEnergy\s*=\s*$nruns\b" "$dir/job.job" \
    && grep -q "path_to_input\s*=\s*'$HEPMC_WORK/buuinput'" "$dir/job.job" \
    || { echo "GIBUU: job card substitution failed"; return 2; }
  cp "$dir/job.job" "$HEPMC_JOBDIR/gibuu_$(basename "$dir").job"

  ( cd "$dir" && env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$HEPMC_WORK/lib" \
      timeout "$HEPMC_TIMEOUT" "$HEPMC_WORK/GiBUU.x" < job.job > generator.log 2>&1 )
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -q "You have to increase 'equalWeights_Max'" "$dir/generator.log"; then
      # a trial weight above Max: the attempt is discarded and redone with a new seed.
      # This drops the (tiny) part of the cross section above Max; count these!
      echo "GIBUU: weight above equalWeights_Max (attempt discarded)"; return 1
    fi
    if grep -q "Negative weight" "$dir/generator.log"; then
      echo "GIBUU: negative weight in equal-weights mode (needs a different setup)"; return 2
    fi
    [ "$rc" -eq 124 ] && { echo "GIBUU: timeout"; return 1; }
    echo "GIBUU: GiBUU.x exited with $rc"; return 1
  fi
  return 0
}

gen_validate() {
  local dir=$1 seed=$2
  local hep=$dir/EventOutput.Pert.hepmc3
  grep -q "BUU simulation: finished" "$dir/generator.log" || { echo "GiBUU did not finish"; return 1; }
  [ -s "$hep" ] || { echo "no EventOutput.Pert.hepmc3"; return 1; }
  [ "$(tail -n 1 "$hep")" = "HepMC::Asciiv3-END_EVENT_LISTING" ] || { echo "hepmc3 output truncated"; return 1; }
  local hseed; hseed=$(awk '/^A GiBUU.RandomSeed/{print $3; exit}' "$hep")
  [ "$hseed" = "$seed" ] || { echo "seed in output ($hseed) != requested ($seed)"; return 1; }
  local nbad; nbad=$(awk -v w="$GIBUU_EXPECTED_W" '/^W /&&NF==2&&$2~/^[-+0-9.eE]+$/{
      if ($2/w-1>1e-6 || 1-$2/w>1e-6) n++ } END{print n+0}' "$hep")
  [ "$nbad" -eq 0 ] || { echo "$nbad events with weight != $GIBUU_EXPECTED_W"; return 1; }
  grep -c '^E ' "$hep"
}

gen_convert() {
  local out=$1 seed=$2; shift 2
  local f=() d
  for d in "$@"; do f+=("$d/EventOutput.Pert.hepmc3"); done
  # shellcheck disable=SC2086
  "$HEPMC_WORK/gibuu_to_hepmc" -o "$out" -s "$seed" -w "$GIBUU_EXPECTED_W" $HEPMC_CONVERTER_OPTS "${f[@]}"
}

gen_info() {
  echo "card=$GIBUU_JOBCARD max=$GIBUU_EQUALWEIGHTS_MAX numEnsembles=$GIBUU_NUM_ENSEMBLES A=$GIBUU_A weight=$GIBUU_EXPECTED_W"
}
