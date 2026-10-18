#!/usr/bin/env python3
"""
check_production.py -- bookkeeping checks for a hepmc_grid_init.sh production.

Point it at the project's log directory. condor_lar.sh copies, per job, a log.tar
(bzip2) holding every file the job left behind; plain directories are read too.
For every job it uses

  * hepmc_summary.txt -- the HEPMC_SUMMARY lines of hepmc_grid_init.sh (jobs run
    with the current grid script; the same lines also go to the job's stdout), or
  * for older jobs, a reconstruction from the leftover files: gibuu_attempt<N>.job
    (seed, runs, Max, ensembles, A), hepmc_attempt<N>_tail.log (did GiBUU finish?),
    eventcount.meta (events converted), jobid.txt

and then

  * checks that no generator seed was used twice (equal seeds = identical events)
  * with --hepmc, fingerprints the events of every nuwro_input.hepmc and reports
    truth events that appear in more than one job
  * summarises jobs, attempts, retries and failures
  * GiBUU: estimates the flux-averaged cross section and, with --flux, the POT per
    event for hepmc_POT.meta. First attempts only when their event counts are known
    (their run count is fixed before any event is seen, so no stopping-rule bias);
    otherwise all attempts, which is biased by O(1/N) and says so.

Jobs that failed in the grid script exit before condor_lar.sh copies any logs; they
only appear in the jobsub stdout (HEPMC_SUMMARY status=FAILED). Point the script at
fetched job logs (jobsub_fetchlog) to include them.

Usage:
  check_production.py LOGDIR [LOGDIR ...] [--hepmc] [--flux FLUX.dat]
                      [--box 257 232 1037] [--density 1.3954] [-v]
"""
import argparse
import collections
import math
import os
import re
import sys
import tarfile

KV = re.compile(r'(\w+)=("[^"]*"|\S+)')
ATTEMPT_CARD = re.compile(r'gibuu_attempt(\d+)\.job$')
ATTEMPT_TAIL = re.compile(r'hepmc_attempt(\d+)_tail\.log$')
TEXT_SUFFIXES = ('.out', '.log', '.txt', '.err')
TAR_SUFFIXES = ('.tar', '.tar.bz2', '.tbz2', '.tar.gz', '.tgz')


class Job:
    """The files of one job that matter here (name -> text), from a tar or a directory."""

    def __init__(self, origin):
        self.origin = origin
        self.files = {}

    def wanted(self, name):
        b = os.path.basename(name)
        return (b.endswith(TEXT_SUFFIXES) or b.endswith('.meta') or b.endswith('.job')
                or b == 'nuwro_input.hepmc' or b.endswith('_nuwro_input.hepmc'))

    def add(self, name, text):
        self.files[os.path.basename(name)] = text


def jobs_in(paths):
    """Yield one Job per log.tar / tar archive, plus one per directory with loose files."""
    for top in paths:
        for root, _, files in os.walk(top):
            loose = Job(root)
            for f in sorted(files):
                p = os.path.join(root, f)
                if f.endswith(TAR_SUFFIXES):
                    job = Job(p)
                    try:
                        with tarfile.open(p, 'r:*') as tf:
                            for m in tf:
                                if m.isfile() and job.wanted(m.name):
                                    job.add(m.name, tf.extractfile(m).read().decode(errors='replace'))
                    except (tarfile.TarError, OSError, EOFError) as e:
                        print(f"WARNING: cannot read {p}: {e}")
                        continue
                    yield job
                elif loose.wanted(f):
                    try:
                        with open(p, errors='replace') as fh:
                            loose.add(f, fh.read())
                    except OSError:
                        pass
            if loose.files:
                yield loose


def summary_lines(job):
    for name, text in job.files.items():
        if name.endswith(TEXT_SUFFIXES):
            for line in text.splitlines():
                if line.startswith('HEPMC_SUMMARY '):
                    yield {k: v.strip('"') for k, v in KV.findall(line)}


def card_value(card, key):
    m = re.search(r'^\s*%s\s*=\s*([-+0-9.eE]+)' % key, card, re.M)
    return m.group(1) if m else None


def reconstruct(job):
    """Rebuild HEPMC_SUMMARY-like records for a GiBUU job from its leftover files."""
    cards = {int(ATTEMPT_CARD.search(n).group(1)): t for n, t in job.files.items() if ATTEMPT_CARD.search(n)}
    if not cards:
        return []
    tails = {int(ATTEMPT_TAIL.search(n).group(1)): t for n, t in job.files.items() if ATTEMPT_TAIL.search(n)}
    jobid = job.files.get('jobid.txt', '').strip() or job.origin
    nconv = job.files.get('eventcount.meta', '').strip()
    recs, ok = [], []
    weight = None
    for i in sorted(cards):
        c = cards[i]
        mx, ne, a = card_value(c, 'equalWeights_Max'), card_value(c, 'numEnsembles'), card_value(c, 'A')
        if mx and ne and a:
            weight = '%.15g' % (float(mx) / (float(a) * float(ne)))
        finished = 'BUU simulation: finished' in tails.get(i, '')
        r = {'attempt': str(i), 'status': 'OK' if finished else 'GENERATOR_FAILED',
             'seed': card_value(c, 'SEED'), 'units': card_value(c, 'num_runs_SameEnergy'),
             'jobid': jobid, 'reconstructed': '1'}
        if weight:
            r['weight'] = weight
        recs.append(r)
        if finished:
            ok.append(r)
    if len(ok) == 1 and nconv:
        ok[0]['events'] = nconv           # a single successful attempt made all events
    if nconv:
        recs.append({'status': 'OK', 'generator': 'gibuu', 'attempts': str(len(cards)),
                     'events': nconv, 'units': str(sum(int(r['units']) for r in ok if r['units'])),
                     'jobid': jobid, 'reconstructed': '1'})
    return recs


def fingerprints(text):
    """One key per event: neutrino and all final-state momenta (vertex/time excluded)."""
    lines = text.split('\n')
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
    ap.add_argument('-v', '--verbose', action='store_true', help='one line per job')
    a = ap.parse_args()

    seeds = collections.defaultdict(set)
    jobs_ok, jobs_failed, fail_reasons = {}, {}, collections.Counter()
    attempts = []
    hepmc = []                 # (jobid, text)
    nsources = nrecon = nnothing = 0
    for job in jobs_in(a.logdirs):
        nsources += 1
        recs = list(summary_lines(job))
        if not recs:
            recs = reconstruct(job)
            nrecon += bool(recs)
        if not recs:
            nnothing += 1
            if a.verbose:
                print(f"  no grid-script information in {job.origin}")
        jobid = job.files.get('jobid.txt', '').strip() or job.origin
        for d in recs:
            if 'attempt' in d:
                attempts.append(d)
                if d.get('seed'):
                    seeds[d['seed']].add(d.get('jobid', jobid))
            elif d.get('status') == 'OK':
                jobs_ok[d.get('jobid', jobid)] = d
            elif d.get('status') == 'FAILED':
                jobs_failed[d.get('jobid', jobid)] = d
                fail_reasons[d.get('reason', '?')] += 1
        if a.verbose and recs:
            fin = [d for d in recs if 'attempt' not in d]
            print(f"  {jobid}: {len(recs) - len(fin)} attempt(s), "
                  f"{fin[0].get('events', '?') if fin else '?'} events{' (reconstructed)' if recs[0].get('reconstructed') else ''}")
        for name, text in job.files.items():
            if name == 'nuwro_input.hepmc' or name.endswith('_nuwro_input.hepmc'):
                hepmc.append((jobid, text))

    print(f"read {nsources} job archives/directories: {nsources - nrecon - nnothing} with hepmc_summary, "
          f"{nrecon} reconstructed from leftover files, {nnothing} without grid-script information")
    print(f"jobs OK: {len(jobs_ok)}   jobs FAILED: {len(jobs_failed)}   attempts: {len(attempts)}")
    for r, c in fail_reasons.most_common(10):
        print(f"   {c:6d} x {r}")
    nfa = sum(1 for d in attempts if d.get('status') == 'GENERATOR_FAILED')
    nretry = sum(1 for d in jobs_ok.values() if int(d.get('attempts', 1)) > 1)
    print(f"generator failures (attempts discarded): {nfa}   successful jobs that needed >1 attempt: {nretry}")
    if jobs_ok:
        ev = [int(d['events']) for d in jobs_ok.values() if d.get('events', '').isdigit()]
        if ev:
            print(f"events per job: min {min(ev)}  mean {sum(ev) / len(ev):.1f}  max {max(ev)}")

    dup = {s: j for s, j in seeds.items() if len(j) > 1}   # same seed in two different jobs
    if dup:
        print(f"ERROR: {len(dup)} seeds used by more than one job -> identical events!")
        for s, j in list(dup.items())[:20]:
            print(f"   seed {s}: {sorted(j)}")
    else:
        print(f"seeds: {len(seeds)} distinct, no duplicates")

    gibuu = [d for d in attempts if d.get('status') == 'OK' and d.get('weight') and d.get('units')]
    if gibuu:
        ws = {d['weight'] for d in gibuu}
        if len(ws) > 1:
            print(f"ERROR: different event weights in one sample: {sorted(ws)} (Max/numEnsembles changed?)")
        first = [d for d in gibuu if d.get('attempt') == '0']
        if first and all('events' in d for d in first):
            use, label = first, 'first attempts'
        else:
            # some first-attempt counts are unknown (old jobs with retries): use job totals
            use = [d for d in jobs_ok.values() if d.get('events') and d.get('units')]
            label = 'all attempts (includes retries: O(1/N) stopping-rule bias)'
        if use:
            w = float(next(iter(ws)))
            n = sum(int(d['events']) for d in use)
            runs = sum(int(d['units']) for d in use)
            sig = n * w / runs
            print(f"GiBUU, {label}: {len(use)} jobs, {runs} runs, {n} events, {n / runs:.3f} events/run")
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

    ndup = 0
    if a.hepmc:
        seen = {}
        nev = 0
        for jobid, text in hepmc:
            for k in fingerprints(text):
                nev += 1
                if k in seen and seen[k] != jobid:
                    ndup += 1
                    if ndup <= 10:
                        print(f"   duplicate event in {jobid} and {seen[k]}")
                seen.setdefault(k, jobid)
        print(f"hepmc files: {len(hepmc)}, events: {nev}, duplicated events across jobs: {ndup}")

    sys.exit(1 if dup or ndup else 0)


if __name__ == '__main__':
    main()
