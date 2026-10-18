#!/usr/bin/env python3
"""
make_flux_table.py -- MCC9 flux histogram -> GiBUU-format flux table.

Reads hEnumu_cv (or another histogram) from MCC9_FluxHist_volTPCActive.root and writes
a table in the format of GiBUU's buuinput/neutrino/BNB_numu.dat:
    bin centre [GeV]   neutrinos per 1e20 POT per cm2 per bin

The histogram holds raw neutrino counts through the TPC active volume, from 4997
flux files of 5e8 POT each; the area is the TPC front face, 256.35 x 233 cm2
(standard MicroBooNE normalisation of this file).

The same table feeds GiBUU (installed as BNB_numu.dat by build/make_tarball_gibuu.sh),
NuWro (prod_nuwro/params/make_nuwro_beam.sh) and the POT normalisation
(validation/check_production.py --flux). Needs uproot (only to regenerate the table).

Usage: make_flux_table.py [--hist hEnumu_cv] [--root FILE] > BNB_numu_uboone_mcc9.dat
"""
import argparse
import os
import uproot

FLUX_POT = 4997 * 5e8          # POT behind the histogram
AREA_CM2 = 256.35 * 233.0       # TPC front face

ap = argparse.ArgumentParser()
ap.add_argument('--root', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                               'MCC9_FluxHist_volTPCActive.root'))
ap.add_argument('--hist', default='hEnumu_cv')
a = ap.parse_args()

counts, edges = uproot.open(a.root)[a.hist].to_numpy()
print(f"# {a.hist} from {os.path.basename(a.root)} (MicroBooNE MCC9 flux, TPC active volume)")
print(f"# normalised to 1e20 POT and 1 cm2: counts / ({FLUX_POT:.4e} POT) / ({AREA_CM2:.2f} cm2) * 1e20")
print("#Enu [GeV]\tFlux [number of neutrinos per 10^20 POT/cm^2/bin]")
for c, lo, hi in zip(counts, edges[:-1], edges[1:]):
    print(f"{0.5 * (lo + hi):.3f}\t{c / FLUX_POT / AREA_CM2 * 1e20:.6e}")
