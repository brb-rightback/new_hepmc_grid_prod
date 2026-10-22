#!/bin/bash
#
# hepmc_grid_init.sh -- generic <initsource> for "generate on the worker node, then
# overlay" productions. Replaces nuwro_script.sh (which copied a pre-made hepmc file).
#
# It runs an event generator on the worker node, validates its output, retries if
# needed, and converts the events to nuwro_input.hepmc, which HepMCFileGen
# (prodhepmc_overlay_uboone.fcl) reads together with hepmc_POT.meta.
#
# The generator-specific part is a plugin inside the tarball: generator_<HEPMC_GENERATOR>.sh
# if present, otherwise generator.sh (see prod_gibuu/generator.sh, prod_gibuu/generator_gibuu_mix.sh
# and prod_nuwro/generator.sh). A plugin defines:
#   gen_setup                          check config/binaries, build the converter
#   gen_units NEED ATTEMPT NEV NUNITS  how many "units" (GiBUU: runs, NuWro: events)
#                                      to request in this attempt to get NEED more events
#                                      (NEV events were made so far in NUNITS units)
#   gen_run DIR SEED UNITS             run the generator in DIR; return 0 ok,
#                                      1 failed but retrying with a new seed is fine,
#                                      2 fatal
#   gen_validate DIR SEED              check the output; print the number of events
#   gen_convert OUT SEED DIR...        convert all attempts into OUT (shuffled)
#   gen_info                           extra key=value fields for the summary line
#
# This file is SOURCED by condor_lar.sh after the larsoft setup and before the SAM
# consumer starts. Therefore:
#   * failures use `return <n>` (never `exit`). NOTE: project.py wraps every init source
#     in init_source_wrapper.sh, which ends with an echo, so condor_lar.sh never sees the
#     status and runs lar anyway. A failure therefore also deletes nuwro_input.hepmc:
#     HepMCFileGen then stops the job, and condor_lar.sh still copies the logs.
#   * no `set -e`, and nothing here changes the caller's environment except the
#     variables/functions prefixed HEPMC_/hepmc_/gen_ (generators run in subshells)
#   * the overlay input file is not known yet, so we always generate
#     HEPMC_NEVENTS_NEEDED events (>= the largest file in the SAM definition)
#
# Files passed with jobsub -f (found in the job directory or $CONDOR_DIR_INPUT):
#   hepmc_grid.cfg     configuration (see prod_*/hepmc_grid.cfg.example)
#   hepmc_POT.meta     POT_Per_Event=... for this sample
#   $HEPMC_TARBALL     generator + plugin + converter source (build/make_tarball_*.sh)
#
# Everything left in the job directory is copied to the log directory by condor_lar.sh,
# so the generator runs in a scratch subdirectory that is removed at the end. The
# HEPMC_SUMMARY lines (job stdout and hepmc_summary.txt, which ends up in log.tar) are
# the bookkeeping record of the production (seeds, events, units);
# validation/check_production.py reads them.

hepmc_log() { echo "HEPMC_GRID: $*"; }

# Bookkeeping line: to stdout (jobsub log) and to hepmc_summary.txt, which condor_lar.sh
# packs into the log.tar copied to the project's log directory.
hepmc_summary() {
  echo "HEPMC_SUMMARY $*"
  echo "HEPMC_SUMMARY $*" >> "${HEPMC_JOBDIR:-.}/hepmc_summary.txt"
}

hepmc_fail() {
  hepmc_log "FATAL: $1"
  hepmc_summary "status=FAILED generator=${HEPMC_GENERATOR:-unknown} reason=\"$1\" seed_base=${HEPMC_SEED_BASE:-unset} jobid=${JOBSUBJOBID:-unknown}"
  cd "$HEPMC_JOBDIR" 2>/dev/null
  # lar runs even after a failed init source (see above): make sure it cannot read events
  rm -f "$HEPMC_JOBDIR/nuwro_input.hepmc" "$HEPMC_JOBDIR/eventcount.meta"
  [ -n "$HEPMC_WORK" ] && rm -rf "$HEPMC_WORK"
  return 1
}

# hepmc_get_tarball: path of the generator tarball. Uses the copy delivered with jobsub -f;
# if that transfer failed, copies HEPMC_TARBALL_PATH (full /pnfs path) with ifdh, up to
# HEPMC_FETCH_TRIES times (default 8; waits 1, 2, 3, 4, 5, 5, ... min between tries,
# ~25 min in total). With HEPMC_TARBALL_MD5 set, the tarball must have that md5sum.
hepmc_get_tarball() {
  local t i sum tries=${HEPMC_FETCH_TRIES:-8}
  t=$(hepmc_find "$HEPMC_TARBALL")
  if [ -n "$t" ] && [ -n "$HEPMC_TARBALL_MD5" ]; then
    sum=$(md5sum "$t" | cut -d' ' -f1)
    if [ "$sum" != "$HEPMC_TARBALL_MD5" ]; then
      hepmc_log "delivered $HEPMC_TARBALL has md5 $sum, expected $HEPMC_TARBALL_MD5" >&2
      case "$t" in "$HEPMC_JOBDIR"/*) rm -f "$t" ;; esac   # keep it out of log.tar
      t=""
    fi
  fi
  if [ -z "$t" ] && [ -n "$HEPMC_TARBALL_PATH" ]; then
    t=$HEPMC_JOBDIR/hepmc_fetched_$HEPMC_TARBALL
    for ((i = 1; i <= tries; i++)); do
      hepmc_log "fetching $HEPMC_TARBALL_PATH (try $i of $tries)" >&2
      rm -f "$t"
      if ifdh cp "$HEPMC_TARBALL_PATH" "$t" >&2 && [ -s "$t" ]; then
        if [ -z "$HEPMC_TARBALL_MD5" ] || [ "$(md5sum "$t" | cut -d' ' -f1)" = "$HEPMC_TARBALL_MD5" ]; then
          echo "$t"; return 0
        fi
        hepmc_log "fetched tarball has the wrong md5sum" >&2
      fi
      [ "$i" -lt "$tries" ] && sleep $(( 60 * (i < 5 ? i : 5) ))
    done
    rm -f "$t"; t=""
  fi
  [ -n "$t" ] && echo "$t"
}

hepmc_find() {  # locate a -f input file
  if [ -f "$HEPMC_JOBDIR/$1" ]; then echo "$HEPMC_JOBDIR/$1"
  elif [ -n "$CONDOR_DIR_INPUT" ] && [ -f "$CONDOR_DIR_INPUT/$1" ]; then echo "$CONDOR_DIR_INPUT/$1"
  fi
}

# ceil((need + z*sqrt(need) + 1) / rate), at least 1. Used by plugins whose yield per
# unit fluctuates (Poisson), e.g. GiBUU events per run.
# hepmc_seed SLOT: the job's seed for slot 0..9. hepmc_grid_init.sh gives attempt N slot N;
# a plugin that runs several generator invocations per attempt (gibuu_mix) takes its
# seeds from here so that every invocation in the job has its own seed.
hepmc_seed() {
  [ "$1" -ge 0 ] && [ "$1" -lt 10 ] || { echo "hepmc_seed: slot $1 outside 0..9" >&2; return 1; }
  echo $(( HEPMC_SEED_BASE + $1 ))
}

hepmc_poisson_units() {
  awk -v n="$1" -v r="$2" -v z="$3" 'BEGIN{ if (n<=0) {print 0; exit}
    x=(n + z*sqrt(n) + 1)/r; u=(x==int(x))?x:int(x)+1; if (u<1) u=1; print u }'
}

hepmc_main() {
  HEPMC_JOBDIR=$PWD
  hepmc_log "starting on $(hostname) at $(date -u), CLUSTER=$CLUSTER PROCESS=$PROCESS JOBSUBJOBID=$JOBSUBJOBID"

  local cfg; cfg=$(hepmc_find hepmc_grid.cfg)
  [ -n "$cfg" ] || { hepmc_fail "hepmc_grid.cfg not found"; return 1; }
  # shellcheck disable=SC1090
  source "$cfg"
  local v
  for v in HEPMC_GENERATOR HEPMC_TARBALL HEPMC_NEVENTS_NEEDED HEPMC_SEED_OFFSET HEPMC_MAX_ATTEMPTS HEPMC_TIMEOUT; do
    [ -n "${!v}" ] || { hepmc_fail "config variable $v not set"; return 1; }
  done
  : "${HEPMC_RETRY_ON_FAILURE:=1}"
  : "${HEPMC_CONVERTER_OPTS:=}"

  local pot_meta; pot_meta=$(hepmc_find hepmc_POT.meta)
  [ -n "$pot_meta" ] || { hepmc_fail "hepmc_POT.meta not found"; return 1; }
  grep -q "^POT_Per_Event=" "$pot_meta" || { hepmc_fail "hepmc_POT.meta has no POT_Per_Event= line"; return 1; }
  [ "$pot_meta" = "$HEPMC_JOBDIR/hepmc_POT.meta" ] || cp "$pot_meta" "$HEPMC_JOBDIR/"

  # ------------------------------------------------------------------ seeds
  # Every generator gets seeds in [1, 942438977]: GiBUU's RANMAR only distinguishes
  # seeds modulo 30082*31329 = 942438978 (NuWro's MT19937 takes any 32 bit value; 0
  # and 1 are special there, which this layout never produces).
  #   seed = 1 + ((HEPMC_SEED_OFFSET + CLUSTER) mod 9000) * 100000 + PROCESS * 10 + attempt
  # Unique for PROCESS < 10000 and attempt < 10 as long as the clusters of a production
  # differ mod 9000. CLUSTER is included because makeup/recovery submissions restart
  # PROCESS at 0. Uniqueness over the production must still be checked afterwards
  # (validation/check_production.py) -- equal seeds give identical events.
  [ -n "$CLUSTER" ] && [ -n "$PROCESS" ] || { hepmc_fail "CLUSTER/PROCESS not set"; return 1; }
  [ "$PROCESS" -lt 10000 ] || { hepmc_fail "PROCESS >= 10000 breaks the seed layout"; return 1; }
  [ "$HEPMC_MAX_ATTEMPTS" -ge 1 ] && [ "$HEPMC_MAX_ATTEMPTS" -lt 10 ] || { hepmc_fail "HEPMC_MAX_ATTEMPTS must be 1..9"; return 1; }
  HEPMC_SEED_BASE=$(( 1 + ((HEPMC_SEED_OFFSET + CLUSTER) % 9000) * 100000 + PROCESS * 10 ))

  # ------------------------------------------------------------------ unpack
  local tarball; tarball=$(hepmc_get_tarball)
  [ -n "$tarball" ] || { hepmc_fail "tarball $HEPMC_TARBALL not found${HEPMC_TARBALL_PATH:+ (and could not be fetched from $HEPMC_TARBALL_PATH)}"; return 1; }
  hepmc_log "using $tarball ($(md5sum "$tarball" | cut -d' ' -f1))"
  HEPMC_WORK=$HEPMC_JOBDIR/hepmc_work
  rm -rf "$HEPMC_WORK"
  mkdir -p "$HEPMC_WORK" && tar -xzf "$tarball" -C "$HEPMC_WORK" || { hepmc_fail "cannot unpack $tarball"; return 1; }
  # condor_lar.sh copies the -f files into the job directory, and everything left there
  # ends up in log.tar: do not ship 60+ MB of tarball back with every job's logs
  case "$tarball" in "$HEPMC_JOBDIR"/*) rm -f "$tarball" ;; esac
  local plugin=$HEPMC_WORK/generator_${HEPMC_GENERATOR}.sh
  [ -f "$plugin" ] || plugin=$HEPMC_WORK/generator.sh
  [ -f "$plugin" ] || { hepmc_fail "no generator plugin for '$HEPMC_GENERATOR' in the tarball"; return 1; }
  # shellcheck disable=SC1090
  source "$plugin"
  [ "$GEN_NAME" = "$HEPMC_GENERATOR" ] || { hepmc_fail "tarball contains generator '$GEN_NAME', config asks for '$HEPMC_GENERATOR'"; return 1; }
  gen_setup || { hepmc_fail "gen_setup failed"; return 1; }

  # ------------------------------------------------------------------ generate
  local have=0 units_done=0 attempt=0 failures=0 dirs=()
  while [ "$have" -lt "$HEPMC_NEVENTS_NEEDED" ]; do
    [ "$attempt" -lt "$HEPMC_MAX_ATTEMPTS" ] || { hepmc_fail "only $have of $HEPMC_NEVENTS_NEEDED events after $attempt attempts"; return 1; }
    local seed=$(( HEPMC_SEED_BASE + attempt ))
    local need=$(( HEPMC_NEVENTS_NEEDED - have ))
    local units; units=$(gen_units "$need" "$attempt" "$have" "$units_done")
    [ -n "$units" ] && [ "$units" -ge 1 ] || { hepmc_fail "gen_units returned '$units'"; return 1; }
    local dir=$HEPMC_WORK/attempt$attempt
    mkdir -p "$dir"
    hepmc_log "attempt $attempt: seed=$seed units=$units (have $have, need $HEPMC_NEVENTS_NEEDED)"

    local t0; t0=$(date +%s)
    gen_run "$dir" "$seed" "$units"
    local rc=$?
    local dt=$(( $(date +%s) - t0 ))
    hepmc_log "attempt $attempt: generator returned $rc after $dt s"
    [ -f "$dir/generator.log" ] && tail -n 200 "$dir/generator.log" > "$HEPMC_JOBDIR/hepmc_attempt${attempt}_tail.log"

    if [ "$rc" -ne 0 ]; then
      hepmc_summary "attempt=$attempt status=GENERATOR_FAILED rc=$rc seed=$seed units=$units seconds=$dt jobid=${JOBSUBJOBID:-unknown}"
      if [ "$rc" -eq 1 ] && [ "$HEPMC_RETRY_ON_FAILURE" = "1" ]; then
        failures=$(( failures + 1 ))
        attempt=$(( attempt + 1 ))
        continue
      fi
      hepmc_fail "generator failed (rc=$rc) in attempt $attempt"; return 1
    fi

    local n; n=$(gen_validate "$dir" "$seed")
    local vrc=$?
    [ "$vrc" -eq 0 ] && [ -n "$n" ] || { hepmc_fail "validation failed in attempt $attempt: $n"; return 1; }
    hepmc_summary "attempt=$attempt status=OK seed=$seed units=$units events=$n seconds=$dt $(gen_info) jobid=${JOBSUBJOBID:-unknown}"
    dirs+=("$dir")
    have=$(( have + n ))
    units_done=$(( units_done + units ))
    attempt=$(( attempt + 1 ))
  done

  # ------------------------------------------------------------------ convert
  ( cd "$HEPMC_JOBDIR" && gen_convert nuwro_input.hepmc "$HEPMC_SEED_BASE" "${dirs[@]}" ) \
    || { hepmc_fail "conversion failed"; return 1; }
  local nconv; nconv=$(cat "$HEPMC_JOBDIR/eventcount.meta" 2>/dev/null)
  [ "$nconv" = "$have" ] && [ "$nconv" -ge "$HEPMC_NEVENTS_NEEDED" ] \
    || { hepmc_fail "converted '$nconv' events, expected $have (>= $HEPMC_NEVENTS_NEEDED)"; return 1; }
  local nlines; nlines=$(awk 'NF==2' "$HEPMC_JOBDIR/nuwro_input.hepmc" | wc -l)
  [ "$nlines" -eq "$nconv" ] || { hepmc_fail "nuwro_input.hepmc has $nlines event headers, expected $nconv"; return 1; }

  hepmc_summary "status=OK generator=$HEPMC_GENERATOR seed_base=$HEPMC_SEED_BASE attempts=$attempt failed_attempts=$failures units=$units_done events=$have converted=$nconv needed=$HEPMC_NEVENTS_NEEDED $(gen_info) jobid=${JOBSUBJOBID:-unknown}"

  rm -rf "$HEPMC_WORK"
  cd "$HEPMC_JOBDIR"
  return 0
}

hepmc_main
