#!/bin/bash
# GiBUU multi-channel plugin for common/hepmc_grid_init.sh (HEPMC_GENERATOR=gibuu_mix).
#
# Makes one equal-weight sample containing several neutrino flavours and currents
# (e.g. numu, numubar, nue, nuebar x CC, NC). GiBUU generates one flavour and current
# per invocation, so each job:
#   1. reads the channel table (prod_gibuu/mix/*.channels): per channel the GiBUU
#      settings, the flux-averaged cross section sigma_c (calibration, 1e-38 cm2 per
#      nucleon), the flux integral Phi_c (nu/POT/cm2) and an optional enrichment e_c
#   2. draws the number of events per channel from a multinomial distribution with
#      q_c = Phi_c sigma_c e_c / sum_k Phi_k sigma_k e_k
#   3. runs one GiBUU invocation per channel with n_c > 0, built from GIBUU_JOBCARD by
#      changing only process_ID, flavor_ID, nuExp, equalWeights_Max and numEnsembles
#      (so all channels share the same physics settings), sized so that it falls short
#      with probability < GIBUU_MIX_EPS
#   4. keeps exactly n_c random events of each channel (converter --groups), so the
#      mixture is set by the draw alone, and writes the event weight
#      w_c = p_c / q_c (p_c = Phi_c sigma_c / sum Phi sigma); w_c = 1 without enrichment.
# The normalisation is one number: POT_Per_Event = 1 / (N_nucleons * sum_c Phi_c sigma_c).
# gen_setup refuses to run if hepmc_POT.meta disagrees with it by more than 0.5%.
#
# Seeds: channel k (table row k) uses hepmc_seed k, slots 8 and 9 are for up to two
# retry invocations (any channel). Hence at most 8 channels and HEPMC_MAX_ATTEMPTS=1.
#
# Config (hepmc_grid.cfg):
#   GIBUU_JOBCARD        base card (numu CC) in jobcards/
#   GIBUU_MIX_CHANNELS   channel table in mix/
#   GIBUU_A              target mass number
#   GIBUU_MIX_EPS        per-channel shortfall probability of the first invocation (default 1e-3)
#   GIBUU_MIX_NUCLEONS   nucleons in the vertex volume (default: TPC active box, LAr 1.3954 g/cm3)

GEN_NAME=gibuu_mix

gen_setup() {
  local v
  for v in GIBUU_JOBCARD GIBUU_MIX_CHANNELS GIBUU_A; do
    [ -n "${!v}" ] || { echo "GIBUU_MIX: config variable $v not set"; return 1; }
  done
  : "${GIBUU_MIX_EPS:=1e-3}"
  : "${GIBUU_MIX_NUCLEONS:=$(awk 'BEGIN{printf "%.6e", 257*232*1037*1.3954*6.02214076e23}')}"
  [ "$HEPMC_MAX_ATTEMPTS" = "1" ] || { echo "GIBUU_MIX: set HEPMC_MAX_ATTEMPTS=1 (retries are done per channel inside the plugin)"; return 1; }

  local base=$HEPMC_WORK/jobcards/$GIBUU_JOBCARD
  local table=$HEPMC_WORK/mix/$GIBUU_MIX_CHANNELS
  [ -f "$base" ] || { echo "GIBUU_MIX: base card $base not in tarball"; return 1; }
  [ -f "$table" ] || { echo "GIBUU_MIX: channel table $table not in tarball"; return 1; }
  [ -x "$HEPMC_WORK/GiBUU.x" ] && [ -d "$HEPMC_WORK/buuinput" ] || { echo "GIBUU_MIX: GiBUU.x or buuinput missing"; return 1; }
  grep -Eq "^\s*equalWeights_Mode\s*=\s*2\b" "$base" || { echo "GIBUU_MIX: base card is not in equalWeights_Mode=2"; return 1; }
  grep -Eq "^\s*A\s*=\s*${GIBUU_A}\b" "$base" || { echo "GIBUU_MIX: A in base card != $GIBUU_A"; return 1; }

  # channel table -> arrays
  MIX_NAME=(); MIX_PROC=(); MIX_FLAV=(); MIX_EXP=(); MIX_PDG=(); MIX_CCNC=()
  MIX_MAX=(); MIX_NENS=(); MIX_SIG=(); MIX_FLUX=(); MIX_ENR=()
  local name proc flav exp pdg ccnc mx nens sig flux enr rest
  while read -r name proc flav exp pdg ccnc mx nens sig flux enr rest; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$enr" ] || { echo "GIBUU_MIX: short line in $GIBUU_MIX_CHANNELS for $name"; return 1; }
    MIX_NAME+=("$name"); MIX_PROC+=("$proc"); MIX_FLAV+=("$flav"); MIX_EXP+=("$exp"); MIX_PDG+=("$pdg")
    MIX_CCNC+=("$ccnc"); MIX_MAX+=("$mx"); MIX_NENS+=("$nens"); MIX_SIG+=("$sig"); MIX_FLUX+=("$flux"); MIX_ENR+=("$enr")
  done < "$table"
  MIX_N=${#MIX_NAME[@]}
  [ "$MIX_N" -ge 1 ] && [ "$MIX_N" -le 8 ] || { echo "GIBUU_MIX: need 1..8 channels, table has $MIX_N"; return 1; }

  # per-channel cards (only these five lines change)
  mkdir -p "$HEPMC_WORK/mixcards"
  local k card
  for ((k = 0; k < MIX_N; k++)); do
    card=$HEPMC_WORK/mixcards/${MIX_NAME[$k]}.job
    sed -e "s|^\(\s*process_ID\s*=\s*\)[-0-9]*|\1${MIX_PROC[$k]}|" \
        -e "s|^\(\s*flavor_ID\s*=\s*\)[0-9]*|\1${MIX_FLAV[$k]}|" \
        -e "s|^\(\s*nuExp\s*=\s*\)[0-9]*|\1${MIX_EXP[$k]}|" \
        -e "s|^\(\s*equalWeights_Max\s*=\s*\)[0-9.eE+-]*|\1${MIX_MAX[$k]}|" \
        -e "s|^\(\s*numEnsembles\s*=\s*\)[0-9]*|\1${MIX_NENS[$k]}|" "$base" > "$card"
    grep -Eq "^\s*process_ID\s*=\s*${MIX_PROC[$k]}\b" "$card" && grep -Eq "^\s*flavor_ID\s*=\s*${MIX_FLAV[$k]}\b" "$card" \
      && grep -Eq "^\s*nuExp\s*=\s*${MIX_EXP[$k]}\b" "$card" && grep -Eq "^\s*equalWeights_Max\s*=\s*${MIX_MAX[$k]}\b" "$card" \
      && grep -Eq "^\s*numEnsembles\s*=\s*${MIX_NENS[$k]}\b" "$card" \
      || { echo "GIBUU_MIX: card substitution failed for ${MIX_NAME[$k]}"; return 1; }
    [ "$(diff "$base" "$card" | grep -c '^>')" -le 5 ] || { echo "GIBUU_MIX: more than 5 lines differ for ${MIX_NAME[$k]}"; return 1; }
  done

  # sampling probabilities, output weights, GiBUU weights, yields per run
  local probs
  probs=$(for ((k = 0; k < MIX_N; k++)); do echo "${MIX_SIG[$k]} ${MIX_FLUX[$k]} ${MIX_ENR[$k]} ${MIX_MAX[$k]} ${MIX_NENS[$k]}"; done | \
    awk -v A="$GIBUU_A" '{ s[NR]=$1; f[NR]=$2; e[NR]=$3; m[NR]=$4; n[NR]=$5; P+=$1*$2; Q+=$1*$2*$3 }
      END { for (i=1;i<=NR;i++) { p=s[i]*f[i]/P; q=s[i]*f[i]*e[i]/Q;
              printf "%.12g %.12g %.12g %.15g %.12g\n", p, q, p/q, m[i]/(A*n[i]), s[i]*A*n[i]/m[i] }
            printf "SUM %.12e\n", P }')
  MIX_P=(); MIX_Q=(); MIX_W=(); MIX_GW=(); MIX_RATE=()
  local p q w gw rate
  while read -r p q w gw rate; do
    [ "$p" = "SUM" ] && { MIX_SIGFLUX=$q; continue; }
    MIX_P+=("$p"); MIX_Q+=("$q"); MIX_W+=("$w"); MIX_GW+=("$gw"); MIX_RATE+=("$rate")
  done <<< "$probs"

  # normalisation check against hepmc_POT.meta
  MIX_POT_PER_EVENT=$(awk -v sf="$MIX_SIGFLUX" -v nt="$GIBUU_MIX_NUCLEONS" 'BEGIN{printf "%.6e", 1/(sf*1e-38*nt)}')
  local meta; meta=$(awk -F= '/^POT_Per_Event=/{print $2}' "$HEPMC_JOBDIR/hepmc_POT.meta")
  awk -v a="$meta" -v b="$MIX_POT_PER_EVENT" 'BEGIN{ d=a/b-1; exit !(d < 0.005 && d > -0.005) }' \
    || { echo "GIBUU_MIX: hepmc_POT.meta has POT_Per_Event=$meta, the channel table implies $MIX_POT_PER_EVENT"; return 1; }

  local missing
  missing=$(env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$HEPMC_WORK/lib" ldd "$HEPMC_WORK/GiBUU.x" | grep "not found")
  [ -z "$missing" ] || { echo "GIBUU_MIX: GiBUU.x has unresolved libraries: $missing"; return 1; }
  ( cd "$HEPMC_WORK" && g++ -O2 -std=c++11 -o gibuu_to_hepmc gibuu_to_hepmc.cc ) \
    || { echo "GIBUU_MIX: cannot compile gibuu_to_hepmc"; return 1; }

  # multinomial draw of the events per channel (seeded by the job, mt19937_64)
  MIX_NEED=($("$HEPMC_WORK/gibuu_to_hepmc" --draw "$HEPMC_NEVENTS_NEEDED" "$HEPMC_SEED_BASE" "${MIX_Q[@]}"))
  [ "${#MIX_NEED[@]}" -eq "$MIX_N" ] || { echo "GIBUU_MIX: multinomial draw failed"; return 1; }

  echo "GIBUU_MIX: table=$GIBUU_MIX_CHANNELS base=$GIBUU_JOBCARD POT_Per_Event=$MIX_POT_PER_EVENT"
  printf "GIBUU_MIX: %-10s %10s %10s %8s %6s %6s %8s %5s\n" channel p q weight Max nEns ev/run need
  for ((k = 0; k < MIX_N; k++)); do
    printf "GIBUU_MIX: %-10s %10.5f %10.5f %8.4f %6s %6s %8.3f %5d\n" "${MIX_NAME[$k]}" "${MIX_P[$k]}" "${MIX_Q[$k]}" \
      "${MIX_W[$k]}" "${MIX_MAX[$k]}" "${MIX_NENS[$k]}" "${MIX_RATE[$k]}" "${MIX_NEED[$k]}"
  done
  return 0
}

# smallest number of runs r such that P(Poisson(rate*r) >= need) >= 1 - eps
mix_runs() {
  awk -v n="$1" -v r="$2" -v eps="$3" 'BEGIN {
    for (runs = int(n / r) + 1; ; runs++) {
      lam = r * runs; t = exp(-lam); cdf = t
      for (i = 1; i < n; i++) { t *= lam / i; cdf += t }
      if (n == 0 || cdf <= eps) { print runs; exit }
    } }'
}

mix_card_run() {  # mix_card_run CHANNEL_INDEX DIR SEED RUNS
  local k=$1 dir=$2 seed=$3 runs=$4
  mkdir -p "$dir"
  sed -e "s|^\(\s*SEED\s*=\s*\)[-0-9]*|\1$seed|" \
      -e "s|^\(\s*num_runs_SameEnergy\s*=\s*\)[0-9]*|\1$runs|" \
      -e "s|^\(\s*path_to_input\s*=\s*\)'[^']*'|\1'$HEPMC_WORK/buuinput'|" \
      "$HEPMC_WORK/mixcards/${MIX_NAME[$k]}.job" > "$dir/job.job"
  grep -Eq "^\s*SEED\s*=\s*$seed\b" "$dir/job.job" && grep -Eq "^\s*num_runs_SameEnergy\s*=\s*$runs\b" "$dir/job.job" \
    || { echo "GIBUU_MIX: job card substitution failed"; return 2; }
  cp "$dir/job.job" "$HEPMC_JOBDIR/gibuu_mix_$(basename "$dir").job"
  ( cd "$dir" && env -u LD_LIBRARY_PATH LD_LIBRARY_PATH="$HEPMC_WORK/lib" \
      timeout "$HEPMC_TIMEOUT" "$HEPMC_WORK/GiBUU.x" < job.job > generator.log 2>&1 )
  local rc=$?
  tail -n 100 "$dir/generator.log" > "$HEPMC_JOBDIR/hepmc_mix_$(basename "$dir")_tail.log"
  if [ "$rc" -ne 0 ]; then
    grep -q "You have to increase 'equalWeights_Max'" "$dir/generator.log" && { echo "weight above equalWeights_Max"; return 1; }
    grep -q "Negative weight" "$dir/generator.log" && { echo "negative weight in equal-weights mode"; return 2; }
    [ "$rc" -eq 124 ] && { echo "timeout"; return 1; }
    echo "GiBUU.x exited with $rc"; return 1
  fi
  local hep=$dir/EventOutput.Pert.hepmc3
  grep -q "BUU simulation: finished" "$dir/generator.log" || { echo "GiBUU did not finish"; return 2; }
  [ "$(tail -n 1 "$hep" 2>/dev/null)" = "HepMC::Asciiv3-END_EVENT_LISTING" ] || { echo "hepmc3 output missing or truncated"; return 2; }
  [ "$(awk '/^A GiBUU.RandomSeed/{print $3; exit}' "$hep")" = "$seed" ] || { echo "seed in output != $seed"; return 2; }
  return 0
}

gen_units() { echo "$1"; }   # bookkeeping only: the plugin makes exactly HEPMC_NEVENTS_NEEDED events

gen_run() {
  local dir=$1
  MIX_FILES=()
  local k have runs seed n msg rc retry_slot=8 inv done_runs rate
  for ((k = 0; k < MIX_N; k++)); do
    MIX_FILES[$k]=""
    have=0; inv=0; done_runs=0
    [ "${MIX_NEED[$k]}" -gt 0 ] || continue
    seed=$(hepmc_seed "$k")
    while [ "$have" -lt "${MIX_NEED[$k]}" ]; do
      # retries: the smaller of the table yield and the yield seen so far ((have+1)/runs)
      rate=$(awk -v r="${MIX_RATE[$k]}" -v h="$have" -v d="$done_runs" 'BEGIN{ if (d > 0 && (h+1)/d < r) r = (h+1)/d; print r }')
      runs=$(mix_runs $(( MIX_NEED[k] - have )) "$rate" "$GIBUU_MIX_EPS")
      local sub=$dir/${MIX_NAME[$k]}_$inv
      echo "GIBUU_MIX: ${MIX_NAME[$k]} invocation $inv: seed=$seed runs=$runs (have $have, need ${MIX_NEED[$k]})"
      local t0; t0=$(date +%s)
      msg=$(mix_card_run "$k" "$sub" "$seed" "$runs"); rc=$?
      local dt=$(( $(date +%s) - t0 ))
      if [ "$rc" -eq 0 ]; then
        n=$(grep -c '^E ' "$sub/EventOutput.Pert.hepmc3")
        hepmc_summary "channel=${MIX_NAME[$k]} invocation=$inv status=OK seed=$seed runs=$runs events=$n need=${MIX_NEED[$k]} seconds=$dt gibuu_weight=${MIX_GW[$k]} out_weight=${MIX_W[$k]} sigma_table=${MIX_SIG[$k]} jobid=${JOBSUBJOBID:-unknown}"
        have=$(( have + n ))
        done_runs=$(( done_runs + runs ))
        MIX_FILES[$k]="${MIX_FILES[$k]} $sub/EventOutput.Pert.hepmc3"
      else
        hepmc_summary "channel=${MIX_NAME[$k]} invocation=$inv status=GENERATOR_FAILED reason=\"$msg\" seed=$seed runs=$runs seconds=$dt jobid=${JOBSUBJOBID:-unknown}"
        echo "GIBUU_MIX: ${MIX_NAME[$k]} invocation $inv failed: $msg"
        [ "$rc" -eq 1 ] || return 2
      fi
      if [ "$have" -lt "${MIX_NEED[$k]}" ]; then
        [ "$retry_slot" -le 9 ] || { echo "GIBUU_MIX: out of retry seeds"; return 2; }
        seed=$(hepmc_seed "$retry_slot"); retry_slot=$(( retry_slot + 1 )); inv=$(( inv + 1 ))
      fi
    done
  done
  # groups file for the converter: exactly MIX_NEED[k] events per channel
  {
    echo "# n_take expected_gibuu_weight out_weight nu_pdg ccnc channel files"
    for ((k = 0; k < MIX_N; k++)); do
      echo "${MIX_NEED[$k]} ${MIX_GW[$k]} ${MIX_W[$k]} ${MIX_PDG[$k]} ${MIX_CCNC[$k]} ${MIX_NAME[$k]}${MIX_FILES[$k]}"
    done
  } > "$dir/groups.txt"
  cp "$dir/groups.txt" "$HEPMC_JOBDIR/gibuu_mix_groups.txt"
  return 0
}

gen_validate() {  # every channel reached its count in gen_run; the converter re-checks
  local total=0 k
  for ((k = 0; k < MIX_N; k++)); do total=$(( total + MIX_NEED[k] )); done
  [ "$total" -eq "$HEPMC_NEVENTS_NEEDED" ] || { echo "multinomial counts add up to $total"; return 1; }
  echo "$total"
}

gen_convert() {
  local out=$1 seed=$2 dir=$3
  # shellcheck disable=SC2086
  "$HEPMC_WORK/gibuu_to_hepmc" -o "$out" -s "$seed" --groups "$dir/groups.txt" $HEPMC_CONVERTER_OPTS
}

gen_info() {
  local k counts=""
  for ((k = 0; k < MIX_N; k++)); do counts="$counts${MIX_NAME[$k]}:${MIX_NEED[$k]},"; done
  echo "table=$GIBUU_MIX_CHANNELS base=$GIBUU_JOBCARD pot_per_event=$MIX_POT_PER_EVENT counts=${counts%,}"
}
