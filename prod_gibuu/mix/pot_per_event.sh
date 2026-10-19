#!/bin/bash
# pot_per_event.sh TABLE [NUCLEONS] -> POT_Per_Event for a gibuu_mix channel table:
#   1 / (N_nucleons * sum_c flux_c * sigma_c)
# Default N_nucleons: TPC active box 257 x 232 x 1037 cm3 of LAr (1.3954 g/cm3), as in
# generator_gibuu_mix.sh and validation/check_production.py.
awk -v nt="${2:-$(awk 'BEGIN{printf "%.6e", 257*232*1037*1.3954*6.02214076e23}')}" '
  !/^#/ && NF >= 11 { sf += $9 * $10 }
  END { printf "POT_Per_Event=%.6e\n", 1 / (sf * 1e-38 * nt) }' "$1"
