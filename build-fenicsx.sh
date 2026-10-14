#!/usr/bin/env bash
#
# Build FEniCSx (UFL, Basix, FFCx, DOLFINx C++ and Python) from source
# into the currently active conda environment.
#
# Usage:
#   conda activate fenicsx-dev
#   ./build-fenicsx.sh [options] [DOLFINX_REF]
#
# DOLFINX_REF is any git ref of https://github.com/FEniCS/dolfinx: a
# commit hash, a tag (e.g. v0.10.0) or a branch (default: main).
#
# Unless given explicitly, the UFL/Basix/FFCx refs are taken from the
# chosen DOLFINx commit's .github/workflows/fenicsx-refs.env (the refs
# DOLFINx's own CI uses). When that file says "main" (as it does on the
# DOLFINx main branch), the last commit on that repository's main branch
# made before the DOLFINx commit is used, so that the four packages are
# from the same point in time.
#
# Options:
#   --ufl REF          UFL ref    (default: derived from DOLFINx, see above)
#   --basix REF        Basix ref  (default: derived from DOLFINx)
#   --ffcx REF         FFCx ref   (default: derived from DOLFINx)
#   --build-type TYPE  CMake build type: Release, RelWithDebInfo, Debug,
#                      Developer (default: Release)
#   --jobs N           Parallel build jobs (default: number of CPUs)
#   --src-dir DIR      Where to clone the sources (default: <script dir>/src)
#   --build-dir DIR    Where to put build trees (default: <script dir>/build)
#   --clean            Remove existing build trees before building
#   --no-test          Skip the smoke test at the end
#   -h, --help         Show this help

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dolfinx_ref="main"
ufl_ref=""
basix_ref=""
ffcx_ref=""
build_type="Release"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
src_dir="${script_dir}/src"
build_dir="${script_dir}/build"
clean=0
run_test=1

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ufl) ufl_ref="$2"; shift 2 ;;
    --basix) basix_ref="$2"; shift 2 ;;
    --ffcx) ffcx_ref="$2"; shift 2 ;;
    --build-type) build_type="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --src-dir) src_dir="$2"; shift 2 ;;
    --build-dir) build_dir="$2"; shift 2 ;;
    --clean) clean=1; shift ;;
    --no-test) run_test=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) dolfinx_ref="$1"; shift ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Sanity checks: make sure everything comes from the active conda env
# ---------------------------------------------------------------------------
[[ -n "${CONDA_PREFIX:-}" ]] || die "no conda environment is active (conda activate fenicsx-dev)"
[[ "${CONDA_DEFAULT_ENV:-}" != "base" ]] || die "refusing to build into the conda base environment"

for tool in python mpicc mpiexec cmake ninja pkg-config git; do
  path="$(command -v "$tool" || true)"
  [[ -n "$path" ]] || die "'$tool' not found; is the environment created from environment.yml?"
  [[ "$path" == "$CONDA_PREFIX"/* ]] || die "'$tool' resolves to $path, not to the conda env $CONDA_PREFIX"
done
# Recent conda-forge compiler packages (c-compiler/cxx-compiler >= 2) no
# longer set CC/CXX on activation but install plain clang/clang++ (macOS)
# or gcc/g++ (Linux) into the env, configured to use the env's headers
# and libraries.
if [[ -z "${CC:-}" || -z "${CXX:-}" ]]; then
  if [[ -x "$CONDA_PREFIX/bin/clang" && -x "$CONDA_PREFIX/bin/clang++" ]]; then
    export CC=clang CXX=clang++
  elif [[ -x "$CONDA_PREFIX/bin/gcc" && -x "$CONDA_PREFIX/bin/g++" ]]; then
    export CC=gcc CXX=g++
  else
    die "no C/C++ compiler in $CONDA_PREFIX; are c-compiler/cxx-compiler installed?"
  fi
fi
for tool in "$CC" "$CXX"; do
  path="$(command -v "$tool" || true)"
  [[ "$path" == "$CONDA_PREFIX"/* ]] \
    || die "compiler '$tool' resolves to '$path', not to the conda env $CONDA_PREFIX (try: unset CC CXX)"
done

# Catch a broken toolchain (e.g. a macOS SDK without an arm64 libSystem)
# here rather than halfway through the build.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo 'int main(void) { return 0; }' > "$tmp/t.c"
if ! "$CC" ${CFLAGS:-} ${LDFLAGS:-} "$tmp/t.c" -o "$tmp/t" > "$tmp/cc.log" 2>&1; then
  cat "$tmp/cc.log" >&2
  if [[ "$(uname)" == "Darwin" ]]; then
    echo >&2
    echo "The C compiler cannot link a trivial program. If the error mentions libSystem," >&2
    echo "the default macOS SDK is probably broken; try e.g." >&2
    echo "  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX12.1.sdk $0 $*" >&2
  fi
  die "C compiler $CC does not work"
fi

# Point the build systems at the conda env only.
export PETSC_DIR="$CONDA_PREFIX"
unset PETSC_ARCH SLEPC_DIR || true
export CMAKE_PREFIX_PATH="$CONDA_PREFIX"
export PKG_CONFIG_PATH="$CONDA_PREFIX/lib/pkgconfig:$CONDA_PREFIX/share/pkgconfig"
export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
export PIP_NO_INDEX=1                  # never pull anything from PyPI
export PYTHONNOUSERSITE=1              # ignore ~/.local / ~/Library/Python

# ---------------------------------------------------------------------------
# Fetch sources
# ---------------------------------------------------------------------------
mkdir -p "$src_dir" "$build_dir"

fetch() {  # fetch <repo name>
  local dir="$src_dir/$1"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --quiet --tags --force --prune origin
  else
    git clone --quiet "https://github.com/FEniCS/$1.git" "$dir"
  fi
}

resolve() {  # resolve <repo name> <ref>  -> commit hash
  local dir="$src_dir/$1" ref="$2" sha
  for candidate in "origin/$ref" "$ref"; do
    if sha="$(git -C "$dir" rev-parse --verify --quiet "${candidate}^{commit}")"; then
      echo "$sha"; return
    fi
  done
  # Possibly a commit that is not on any branch (e.g. from a PR).
  if git -C "$dir" fetch --quiet origin "$ref" 2>/dev/null; then
    git -C "$dir" rev-parse --verify "FETCH_HEAD^{commit}"; return
  fi
  die "could not find ref '$ref' in FEniCS/$1"
}

log "Fetching sources into $src_dir"
for repo in dolfinx ufl basix ffcx; do
  echo "  $repo"
  fetch "$repo"
done

dolfinx_sha="$(resolve dolfinx "$dolfinx_ref")"
dolfinx_date="$(git -C "$src_dir/dolfinx" show -s --format=%cI "$dolfinx_sha")"

# Ref of a companion package as recorded by DOLFINx's CI at that commit.
companion_ref() {  # companion_ref <repo name>
  git -C "$src_dir/dolfinx" show "$dolfinx_sha:.github/workflows/fenicsx-refs.env" 2>/dev/null \
    | sed -n "s/^$1_ref=//p" | tr -d '[:space:]'
}

pick() {  # pick <repo name> <user ref or empty>  -> commit hash
  local repo="$1" ref="$2"
  if [[ -n "$ref" ]]; then
    resolve "$repo" "$ref"; return
  fi
  ref="$(companion_ref "$repo")"
  ref="${ref:-main}"
  if git -C "$src_dir/$repo" rev-parse --verify --quiet "origin/$ref" > /dev/null; then
    # A branch: take its last commit before the DOLFINx commit.
    local sha
    sha="$(git -C "$src_dir/$repo" rev-list -1 --first-parent --before="$dolfinx_date" "origin/$ref")"
    [[ -n "$sha" ]] || die "no commit on $repo/$ref before $dolfinx_date"
    echo "$sha"
  else
    resolve "$repo" "$ref"
  fi
}

ufl_sha="$(pick ufl "$ufl_ref")"
basix_sha="$(pick basix "$basix_ref")"
ffcx_sha="$(pick ffcx "$ffcx_ref")"

describe() {  # describe <repo name> <sha>
  printf '%-8s %s  %s  %s\n' "$1" "$2" \
    "$(git -C "$src_dir/$1" show -s --format='%cs' "$2")" \
    "$(git -C "$src_dir/$1" tag --points-at "$2" | tr '\n' ' ')"
}

log "Building the following commits (build type: $build_type)"
{
  describe dolfinx "$dolfinx_sha"
  describe ufl "$ufl_sha"
  describe basix "$basix_sha"
  describe ffcx "$ffcx_sha"
} | tee "$tmp/commits.txt"

for repo in dolfinx ufl basix ffcx; do
  var="${repo}_sha"
  git -C "$src_dir/$repo" -c advice.detachedHead=false checkout --quiet --force --detach "${!var}"
  git -C "$src_dir/$repo" clean -fdxq
done

if [[ $clean -eq 1 ]]; then
  log "Removing old build trees"
  rm -rf "$build_dir/basix" "$build_dir/dolfinx-cpp" "$build_dir/dolfinx-python"
fi

# --no-deps: all dependencies come from conda, pip must not touch them.
pip_install=(python -m pip install --no-build-isolation --no-deps --check-build-dependencies)

# ---------------------------------------------------------------------------
# UFL, Basix (C++ library + Python bindings), FFCx
# ---------------------------------------------------------------------------
log "Installing UFL"
"${pip_install[@]}" "$src_dir/ufl"

log "Building and installing Basix (C++ and Python)"
"${pip_install[@]}" \
  --config-settings=cmake.build-type="$build_type" \
  --config-settings=build-dir="$build_dir/basix" \
  "$src_dir/basix"

log "Installing FFCx"
"${pip_install[@]}" "$src_dir/ffcx"

# ---------------------------------------------------------------------------
# DOLFINx C++ library, installed into $CONDA_PREFIX
# ---------------------------------------------------------------------------
log "Configuring DOLFINx C++"
# shellcheck disable=SC2086  # CMAKE_ARGS (set by the conda compiler
# activation) is a whitespace separated list of arguments.
cmake -G Ninja \
  -S "$src_dir/dolfinx/cpp" \
  -B "$build_dir/dolfinx-cpp" \
  ${CMAKE_ARGS:-} \
  -DCMAKE_BUILD_TYPE="$build_type" \
  -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX" \
  -DPython3_EXECUTABLE="$(command -v python)" \
  -DDOLFINX_ENABLE_PETSC=ON \
  -DDOLFINX_ENABLE_SLEPC=ON \
  -DDOLFINX_ENABLE_PARMETIS=ON \
  -DDOLFINX_ENABLE_SCOTCH=ON \
  -DDOLFINX_ENABLE_KAHIP=ON \
  -DDOLFINX_ENABLE_ADIOS2=ON \
  -DDOLFINX_ENABLE_SUPERLU_DIST=ON

log "Building DOLFINx C++ ($jobs jobs)"
cmake --build "$build_dir/dolfinx-cpp" --parallel "$jobs"

log "Installing DOLFINx C++ into $CONDA_PREFIX"
cmake --install "$build_dir/dolfinx-cpp"

# ---------------------------------------------------------------------------
# DOLFINx Python interface
# ---------------------------------------------------------------------------
log "Building and installing DOLFINx Python"
"${pip_install[@]}" \
  --config-settings=cmake.build-type="$build_type" \
  --config-settings=build-dir="$build_dir/dolfinx-python" \
  "$src_dir/dolfinx/python"

# Record what was built.
info="$CONDA_PREFIX/share/fenicsx-build-info.txt"
{
  echo "Built $(date -u +%Y-%m-%dT%H:%M:%SZ) by $0 (build type: $build_type)"
  cat "$tmp/commits.txt"
} > "$info"

# ---------------------------------------------------------------------------
# Smoke test: JIT compile and assemble a form, in serial and in parallel
# ---------------------------------------------------------------------------
if [[ $run_test -eq 1 ]]; then
  log "Smoke test"
  cat > "$tmp/smoke.py" << 'EOF'
from mpi4py import MPI

import numpy as np

import dolfinx
import dolfinx.fem.petsc  # noqa: F401  (checks petsc4py integration)
import ufl
from dolfinx import fem, mesh

comm = MPI.COMM_WORLD
msh = mesh.create_unit_square(comm, 16, 16)
V = fem.functionspace(msh, ("Lagrange", 2))
u, v = ufl.TrialFunction(V), ufl.TestFunction(V)
A = dolfinx.fem.petsc.assemble_matrix(fem.form(ufl.inner(ufl.grad(u), ufl.grad(v)) * ufl.dx))
A.assemble()
area = comm.allreduce(fem.assemble_scalar(fem.form(fem.Constant(msh, 1.0) * ufl.dx(domain=msh))))
assert np.isclose(area, 1.0), area
if comm.rank == 0:
    print(f"DOLFINx {dolfinx.__version__} ({dolfinx.git_commit_hash[:12]}) on {comm.size} rank(s): OK")
    print(f"  petsc={dolfinx.has_petsc} slepc={dolfinx.has_slepc} parmetis={dolfinx.has_parmetis} "
          f"ptscotch={dolfinx.has_ptscotch} kahip={dolfinx.has_kahip} adios2={dolfinx.has_adios2} "
          f"superlu_dist={getattr(dolfinx, 'has_superlu_dist', 'n/a')}")
EOF
  mpiexec -n 1 python "$tmp/smoke.py"
  mpiexec -n 2 python "$tmp/smoke.py"
fi

log "Done. Build info written to $info"
cat "$info"
