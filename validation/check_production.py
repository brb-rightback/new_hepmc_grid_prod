#!/usr/bin/env python3
"""
check_production.py -- bookkeeping checks for a hepmc_grid_init.sh production.

Reads the HEPMC_SUMMARY lines that hepmc_grid_init.sh writes to every job log
(the job logs and leftover files end up in the project's log directory), and

  * checks that no generator seed was used twice (equal seeds = identical events)
  * optionally fingerprints the events of every nuwro_input.hepmc it finds
    (--hepmc) and reports duplicated truth events across the production
  * summarises jobs, attempts, retries and failures
  * GiBUU: estimates the flux-averaged cross section from the first attempts only
    (their run count is fixed before any event is seen, so no stopping-rule bias)
    and, with --flux, the POT per event for hepmc_POT.meta

Usage:
  check_production.py LOGDIR [LOGDIR ...] [--hepmc] [--flux FLUX.dat]
                      [--box 257 232 1037] [--density 1.3954]
"""
import argparse
import collections
import math
import os
import re
import sys

KV = re.compile(r'(\w+)=("[^"]*"|\S+)')


def summaries(paths):
    """Yield (file, dict) for every HEPMC_SUMMARY line under paths."""
    for top in paths:
        for root, _, files in os.walk(top):
            for f in files:
                if not (f.endswith('.out') or f.endswith('.log') or f.endswith('.txt')):
                    continue
                p = os.path.join(root, f)
                try:
                    with open(p, errors='replace') as fh:
                        for line in fh:
                            if line.startswith('HEPMC_SUMMARY '):
                                yield p, {k: v.strip('"') for k, v in KV.findall(line)}
                except OSError:
                    pass


def hepmc_files(paths):
    for top in paths:
        for root, _, files in os.walk(top):
            for f in files:
                if f == 'nuwro_input.hepmc' or f.endswith('_nuwro_input.hepmc'):
                    yield os.path.join(root, f)


def fingerprints(path):
    """One key per event: neutrino and all final-state momenta (vertex/time excluded)."""
    with open(path) as fh:
        lines = fh.read().split('\n')
    i = 0
    while i < len(lines):
        head = lines[i].split()
        if len(head) != 2:
            i += 1
            continue
        n = int(head[1])
        parts = [lines[i + 1 + j].split() for j in range(n)]
        yield tuple((p[0], p[1], p[6], p[7], p[8], p[9]) for p in parts)
        i += 1 + n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('logdirs', nargs='+')
    ap.add_argument('--hepmc', action='store_true', help='also look for duplicated events in nuwro_input.hepmc files')
    ap.add_argument('--flux', help='GiBUU-format flux table (GeV, nu/1e20 POT/cm2/bin) for POT per event')
    ap.add_argument('--box', nargs=3, type=float, default=[257., 232., 1037.], help='vertex box [cm]')
    ap.add_argument('--density', type=float, default=1.3954, help='LAr density [g/cm3]')
    a = ap.parse_args()

    seeds = collections.defaultdict(list)
    jobs_ok, jobs_failed, fail_reasons = {}, {}, collections.Counter()
    attempts = []
    for path, d in summaries(a.logdirs):
        if 'attempt' in d:
            attempts.append(d)
            if 'seed' in d:
                seeds[d['seed']].append(d.get('jobid', path))
        elif d.get('status') == 'OK':
            jobs_ok[d.get('jobid', path)] = d
        elif d.get('status') == 'FAILED':
            jobs_failed[d.get('jobid', path)] = d
            fail_reasons[d.get('reason', '?')] += 1

    print(f"jobs OK: {len(jobs_ok)}   jobs FAILED: {len(jobs_failed)}   attempts logged: {len(attempts)}")
    for r, c in fail_reasons.most_common(10):
        print(f"   {c:6d} x {r}")
    nfa = sum(1 for d in attempts if d.get('status') == 'GENERATOR_FAILED')
    nretry = sum(1 for d in jobs_ok.values() if int(d.get('attempts', 1)) > 1)
    print(f"generator failures (attempts discarded): {nfa}   successful jobs that needed >1 attempt: {nretry}")

    dup = {s: j for s, j in seeds.items() if len(set(j)) > 1}   # same seed in two different jobs
    if dup:
        print(f"ERROR: {len(dup)} seeds used more than once -> identical events!")
        for s, j in list(dup.items())[:20]:
            print(f"   seed {s}: {sorted(set(j))}")
    else:
        print(f"seeds: {len(seeds)} distinct, no duplicates")

    gens = {d.get('generator') for d in jobs_ok.values()}
    if 'gibuu' in gens:
        first = [d for d in attempts if d.get('attempt') == '0' and d.get('status') == 'OK' and 'weight' in d]
        ws = {d['weight'] for d in first}
        if len(ws) > 1:
            print(f"ERROR: different event weights in one sample: {sorted(ws)} (Max/numEnsembles changed?)")
        if first:
            w = float(first[0]['weight'])
            n = sum(int(d['events']) for d in first)
            runs = sum(int(d['units']) for d in first)
            sig = n * w / runs
            print(f"GiBUU first attempts: {len(first)} jobs, {runs} runs, {n} events, {n / runs:.3f} events/run")
            print(f"  flux-averaged sigma = {sig:.5f} +- {sig / math.sqrt(n):.5f} x 1e-38 cm2/nucleon")
            if a.flux:
                phi = 0.0
                with open(a.flux) as fh:
                    for line in fh:
                        if line.startswith('#') or len(line.split()) < 2:
                            continue
                        phi += float(line.split()[1])
                phi /= 1e20                                   # nu / POT / cm2
                vol = a.box[0] * a.box[1] * a.box[2]
                nucleons = a.density * vol * 6.02214076e23   # A nucleons per A g/mol
                ev_per_pot = sig * 1e-38 * phi * nucleons
                print(f"  flux {phi:.4e} nu/POT/cm2, {nucleons:.4e} nucleons in the box")
                print(f"  POT_Per_Event={1 / ev_per_pot:.6e}   (+- {100 / math.sqrt(n):.2f}% stat)")

    if a.hepmc:
        seen = {}
        ndup = nev = nfiles = 0
        for f in hepmc_files(a.logdirs):
            nfiles += 1
            for k in fingerprints(f):
                nev += 1
                if k in seen and seen[k] != f:
                    ndup += 1
                    if ndup <= 10:
                        print(f"   duplicate event in {f} and {seen[k]}")
                seen.setdefault(k, f)
        print(f"hepmc files: {nfiles}, events: {nev}, duplicated events across files: {ndup}")

    sys.exit(1 if dup or (a.hepmc and ndup) else 0)


if __name__ == '__main__':
    main()
