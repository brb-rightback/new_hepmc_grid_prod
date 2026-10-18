# prod_hepmc (grid generation)

Generate neutrino events with GiBUU or NuWro **on the grid worker node**, convert them to the
text "hepmc" format read by ubcore's `HepMCFileGen`, and overlay them on extunbiased data in
the same job. This is a successor to [brb-rightback/prod_hepmc](https://github.com/brb-rightback/prod_hepmc):
- the old workflow made large hepmc files locally, copied one to each job, and threw away the unused events
- here each job makes exactly what it needs, with its own seed

Builds follow [afropapp13/BuildEventGenerators](https://github.com/afropapp13/BuildEventGenerators)
(same UPS products, `build/global_vars.sh`), with the newest releases:
- **GiBUU 2025 patch 5** (April 2026)
- **NuWro `NuWro_25_11_1`**

**Status:**
- **Tested locally (AlmaLinux 9 Jupyter node):**
  - GiBUU build, converter and grid script, end to end, including retries
  - NuWro converter (syntax only) and the NuWro patch (applies cleanly)
- **Not yet run on the grid.** NuWro has not been built or run yet: that needs ROOT/Pythia6, which this node lacks.

## Layout

| path | what |
|---|---|
| `build/` | `global_vars.sh` (UPS), `build_gibuu.sh`, `build_nuwro.sh`, `make_tarball_{gibuu,nuwro}.sh` |
| `common/hepmc_grid_init.sh` | the `<initsource>`: config, seeds, unpack, generate with retries, validate, convert, bookkeeping |
| `common/hepmc_text.h` | shared converter code: HepMCFileGen text format, seeded vertex/time, shuffling |
| `prod_gibuu/` | `generator.sh` (plugin), `gibuu_to_hepmc.cc`, job cards, `hepmc_grid.cfg.example`, example XML, GiBUU patch |
| `prod_nuwro/` | `generator.sh` (plugin), `nuwro_to_hepmc.cc`, params + BNB beam file, `hepmc_grid.cfg.example`, example XML, NuWro patch |
| `larsoft/fcl/` | `prodhepmc_overlay_uboone_200.fcl` (HepMCFileGen MaxEvents 200) |
| `validation/check_production.py` | seed uniqueness, duplicate events, retries/failures, GiBUU σ and POT per event |
| `data/` | MicroBooNE geometry for NuWro; `flux/`: MCC9 flux histogram, `make_flux_table.py`, the derived νμ table |

**Adding a generator:** write `prod_<gen>/generator.sh`, defining:
- `gen_setup`, `gen_units`, `gen_run`, `gen_validate`, `gen_convert`, `gen_info` (see the header of `common/hepmc_grid_init.sh`)
- a converter that uses `common/hepmc_text.h`
- a `make_tarball_<gen>.sh`

Nothing in the common script is generator specific.

## What is built where

| step | where | what |
|---|---|---|
| build GiBUU / NuWro (`build/build_*.sh`) | **once, interactively** on a uboone gpvm, inside the SL7 container | compiled binaries in `build/` |
| pack (`build/make_tarball_*.sh`) | same place | `gibuu_grid.tar.gz` / `nuwro_grid.tar.gz`: binaries, input data, cards, converter **source**, plugin |
| copy tarball + `hepmc_grid.cfg` + `hepmc_POT.meta` to `/pnfs/.../resilient` | gpvm | passed to every job with `jobsub -f` |
| unpack, compile the converter (~1 s), run the generator, convert | **grid node**, every job (`common/hepmc_grid_init.sh`) | `nuwro_input.hepmc` |

**Not compiled on the node:** the generators themselves. Building GiBUU takes minutes and NuWro needs the e26 build environment.

**Compiled on the node:** only the small converters, with the job's own compiler. GiBUU's converter uses plain g++. NuWro's converter uses g++ with ROOT from the same e26 setup NuWro runs in. This avoids shipping binaries that depend on the system C library.

**Patches:** applied by the build scripts on the gpvm, never on the node.

## How a job works

1. `condor_lar.sh` sources `hepmc_grid_init.sh` before the SAM file is known. The job therefore generates `HEPMC_NEVENTS_NEEDED` events: at least the largest `event_count` in the input definition.
2. Seed = `1 + ((HEPMC_SEED_OFFSET + CLUSTER) mod 9000)·100000 + PROCESS·10 + attempt`, unique within a production.
   - Makeup jobs restart `PROCESS` at 0, which is why `CLUSTER` is included.
   - GiBUU's RANMAR aliases seeds modulo 942438978; all seeds stay below that.
3. **Attempt 0** asks for enough units (GiBUU runs) to get the events with a `GIBUU_Z`-sigma margin.
   - **Retries** request the remaining events with a 3σ margin, at the lower of the configured and observed yield.
   - A failed generator attempt is redone with a new seed (`HEPMC_RETRY_ON_FAILURE`), e.g. GiBUU stopping on a weight above Max.
4. **Checks on GiBUU output:**
   - exit code
   - "finished" in the log
   - `END_EVENT_LISTING` present (not truncated)
   - seed in the output equals the requested seed
   - every event has weight Max/(A·N_ens)
   - event counts
5. Events are shuffled and written to `nuwro_input.hepmc`. `HepMCFileGen` reads the first N_ext of them, which is an unbiased subset.
6. `HEPMC_SUMMARY` lines in the job log record seeds, runs and events, and are read by `validation/check_production.py`.

## Using it (GiBUU example)

```bash
# on a uboone gpvm, in the SL7 container (the binaries must run on SL7 nodes)
apptainer shell -B /cvmfs,/exp,/pnfs /cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest
cd build && source global_vars.sh && ./build_gibuu.sh && ./make_tarball_gibuu.sh
cp ../prod_gibuu/hepmc_grid.cfg.example hepmc_grid.cfg     # edit
# POT_Per_Event from a calibration (or a previous production): validation/check_production.py --flux ...
echo "POT_Per_Event=3.22e15" > hepmc_POT.meta    # sigma 0.811e-38, MCC9 flux, TPC box
# copy hepmc_grid.cfg, gibuu_grid.tar.gz, hepmc_POT.meta to the <griddir> of prod_gibuu/xml/*.xml
project.py --xml prod_gibuu/xml/prodgibuu_BNB_numuCC_overlay_run4c_reco1.xml --stage reco1 --submit
```

After the production:

```bash
validation/check_production.py <logdir> --hepmc --flux data/flux/BNB_numu_uboone_mcc9.dat
```

## Things that must be true for the sample to be right

**One configuration per sample.** Every job uses the same `equalWeights_Max`, `numEnsembles` and job card. The event weight Max/(A·N_ens) is then constant and POT per event is exact. The plugin checks the weight of every event.

**`HEPMC_NEVENTS_NEEDED` ≥ the largest extunbiased file.** Also set `MaxEvents` (`larsoft/fcl`) to at least this value.
- If the hepmc file runs out, stock `HepMCFileGen` silently reopens it and duplicates events. Keep the SAM definition limited (`event_count <= 200`).

**Seeds are unique.** Check with `check_production.py` after every production, including makeup submissions.

**GiBUU equal weights:**
- Rejection against a fixed Max is exact as long as no weight exceeds Max. GiBUU stops if one does, and the attempt is retried with a new seed. That drops only the part of σ above Max; count these failures.
- Negative weights can't be handled by rejection. GiBUU 2025's default `new_eN=.true.` path (Bosted–Christy background) clips negative σ to 0. The MAID-like background (`new_eN=.false.`) can be negative. `prod_gibuu/patches/gibuu_equalweights_negative.patch` makes GiBUU stop instead of silently dropping such events.

**NuWro (`prod_nuwro/patches/nuwro_grid.patch`):**
- NuWro never seeded Pythia6, so every job would replay the same hadronisation random numbers. The patch seeds it from `random_seed`.
- NuWro rounded channel fractions × N to fixed per-channel counts. With 200 events per job, rare channels are removed or inflated in every job. The patch draws the counts from a multinomial distribution.
- The plugin refuses a NuWro build without the patch.

## GiBUU performance (Max = 5000, 2000 ensembles, EPYC 7542 core)

| quantity | value |
|---|---|
| time per run | ~175 s (≈ linear in numEnsembles) |
| σ̄ (flux-averaged, per nucleon) | see "Flux" below; 0.807 ± 0.004 ×10⁻³⁸ cm² (old build, 2015 flux) |
| accepted events per run | 16·σ̄ (Poisson) → 12.9 for σ̄ = 0.807 |
| CPU per event | ~14 s, independent of numEnsembles |
| memory | 0.47 / 0.56 / 0.74 GB at 1000 / 2000 / 4000 ensembles |
| runs for 200 events | 18 runs at 12.9/run (default `GIBUU_Z=2`) → ~98 % need one attempt, ~53 min; 19 → 99.8 % |

About 90% of the time goes into evaluating cross sections for every trial nucleon. FSI transport is only ~10%, and only ~1 in 6000 trials is accepted at Max=5000. More ensembles therefore do **not** help; **lowering Max** would (time ∝ Max), but the CCQE weight tail is long:
- trial weights above 1000 occur about once per 4×10⁵–6×10⁵ trials
- the largest seen is ~1600

## Physics configuration

- **GiBUU (`prod_gibuu/jobcards/`):** the card of the 2026 run4c equal-weights test production. GiBUU defaults otherwise; in particular, not the `ME_ODW=1` / MINERvA axial form factor settings of the BuildEventGenerators card. The NC card differs only in `process_ID = 3`.
- **NuWro (`prod_nuwro/params/`):** the BuildEventGenerators NuWro card with the MicroBooNE BNB beam, `dyn_lep = 0` (no ν–e scattering) and 10⁷ test events per job (`NUWRO_TEST_EVENTS`; deliberately large, for robust per-job channel fractions and maximum weights; the CPU cost has to be measured on the first test jobs). The vertex volume (TPC box vs cryostat geometry) is still to be decided (`NUWRO_USE_VERTEX`).

## Flux

All three consumers use one table, `data/flux/BNB_numu_uboone_mcc9.dat`:
- GiBUU: `make_tarball_gibuu.sh` installs it as `buuinput/neutrino/BNB_numu.dat`; `GIBUU_BNB_NUMU_FLUX` selects another file, `none` keeps GiBUU's
- NuWro: `prod_nuwro/params/make_nuwro_beam.sh` turns it into `beam_BNB_numu_uboone.txt`
- the POT normalisation: `check_production.py --flux`

The table is `hEnumu_cv` from `data/flux/MCC9_FluxHist_volTPCActive.root` (MicroBooNE MCC9 flux through the TPC active volume), made by `data/flux/make_flux_table.py`.
- The histogram holds raw counts. They are normalised as 4997 flux files × 5×10⁸ POT and the TPC front face, 256.35 × 233 cm².
- This gives 7.38×10⁻¹⁰ ν/POT/cm². It is 2.7% above A. Schukraft's 2015 table, whose shape agrees to ≲0.5% below 2 GeV.

Other flux files:
- GiBUU 2025 patch 5 ships a different `BNB_numu.dat` ("B. Bogart, UMich, April 2026", ⟨E⟩ = 0.744 vs 0.823 GeV, arbitrary units). With patch 5 and the run4c card, σ̄ is 0.738 ± 0.010 ×10⁻³⁸ cm² with it, vs 0.811 ± 0.007 with the MicroBooNE shape.
- The other code changes in patch 5 do not move σ̄.

To switch fluxes, regenerate the table (`make_flux_table.py --hist ...`) and the NuWro beam file, then remeasure σ̄, `GIBUU_EVENTS_PER_RUN` and `POT_Per_Event`.
