#!/bin/bash
# Interactive environment for the generators built in build/ (source on a uboone gpvm,
# inside the SL7 container used for building). Grid jobs do not use this file.

export TERM=screen
REPO_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-${(%):-%x}}" )" && pwd )"
BASE_DIR=$REPO_DIR/build
echo BASE_DIR $BASE_DIR
source ${BASE_DIR}/global_vars.sh

# NuWro
export PYTHIA6=$PYTHIA6_LIBRARY
export NUWRO=${BASE_DIR}/nuwro
export LD_LIBRARY_PATH=${PYTHIA_FQ_DIR}/lib:$NUWRO/lib:$NUWRO/bin:$LD_LIBRARY_PATH
export PATH=$NUWRO/bin:$PATH
echo "NuWro is setup"

# GiBUU (GiBUU.x; gfortran runtime shipped in GiBUU/lib)
export PATH=${PATH}:${BASE_DIR}/GiBUU/release/objects
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${BASE_DIR}/GiBUU/lib
echo "GiBUU is setup"
