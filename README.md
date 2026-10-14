# DOLFINx from source in a conda environment

`environment.yml` holds every dependency of FEniCSx from conda-forge:
compilers, MPICH, PETSc/SLEPc (real), HDF5/ADIOS2 (MPICH builds),
ParMETIS/PT-SCOTCH/KaHIP, nanobind and more. It does not include the
FEniCSx packages themselves. `build-fenicsx.sh` builds UFL, Basix, FFCx
and DOLFINx (C++ and Python) at chosen commits and installs them into
that environment.

## Usage

```bash
conda env create -f environment.yml
conda activate fenicsx-dev
./build-fenicsx.sh <dolfinx commit, tag or branch>   # default: main
```

Sources are cloned into `src/` and build trees are kept in `build/`, so
rebuilding at another commit is incremental (`--clean` starts fresh).
The commits that were built are recorded in
`$CONDA_PREFIX/share/fenicsx-build-info.txt`.

### Matching UFL/Basix/FFCx versions

DOLFINx must be built against matching UFL, Basix and FFCx versions. By
default the script reads `.github/workflows/fenicsx-refs.env` at the
chosen DOLFINx commit:

- **Release tags (≥ v0.10):** the file pins exact versions, and the
  script uses them.
- **Commits on main:** the file says `main`, so the script takes the last
  commit on each companion repository's main branch made *before* the
  DOLFINx commit.

You can override any of these with `--ufl REF`, `--basix REF` and
`--ffcx REF`. Do this for releases older than v0.10, which do not have
the file. Run `./build-fenicsx.sh --help` for all options, including
`--build-type` and `--jobs`.

## Linux (e.g. an Ubuntu 24.04 remote over SSH)

The same files work unchanged on macOS (arm64) and Linux (x86_64 and
aarch64). On Linux the env gets conda-forge's gcc instead of clang.
Nothing from apt is needed, so you don't need sudo on the remote.

1. Install Miniforge on the remote, if it has no conda:

   ```bash
   curl -fsSLO https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh
   bash Miniforge3-Linux-$(uname -m).sh -b -p ~/miniforge3
   ~/miniforge3/bin/conda init bash   # then log out and back in
   ```

2. Copy this directory to the remote, without `src/` and `build/`, which
   are rebuilt there:

   ```bash
   rsync -av --exclude src --exclude build ./ remote:dolfinx-dev-env/
   ```

3. On the remote, run the same commands as above:

   ```bash
   cd ~/dolfinx-dev-env
   conda env create -f environment.yml
   conda activate fenicsx-dev
   ./build-fenicsx.sh <same dolfinx ref as locally>
   ```

To get the same FEniCSx code on both machines, pass the same DOLFINx
ref. If you give a commit hash or tag (not `main`), the companion
UFL/Basix/FFCx commits will match too. Compare
`$CONDA_PREFIX/share/fenicsx-build-info.txt` on the two machines to
check.

Remote-specific tips:

- **Use tmux/screen:** the C++ build takes a while, and a dropped SSH
  connection would kill it.
- **Limit parallel jobs on shared machines:** g++ needs about 1–2 GB of
  RAM per job on the larger DOLFINx files, so use e.g. `--jobs 4`.
- **Multi-node clusters:** the env's MPICH is fine on a single machine.
  To use a cluster's own MPI across nodes, replace `mpich` with
  `mpich=*=external_*` (or `openmpi=*=external_*`, matching the system
  MPI) so that conda packages use the system MPI library.

## Notes

- **Use conda, not mamba:** mamba 2.1.0 does not detect the macOS 27
  version, which breaks the solve. conda ≥ 23.10 uses the same fast
  libmamba solver and works.
- **Complex PETSc:** change `petsc=*=real*` to `petsc=*=complex*` and the
  env name, then create a second environment.
- **Compilers:** conda-forge's `c-compiler`/`cxx-compiler` ≥ 2.0 no longer
  set `CC`/`CXX` on activation. The script falls back to the env's
  `clang`/`clang++` (or `gcc`/`g++` on Linux) and refuses to use a
  compiler, MPI or CMake from outside the env.
- **macOS SDK:** if linking fails with a `libSystem` error, the default
  macOS SDK is broken. Run the script with
  `SDKROOT=/path/to/a/working/MacOSX.sdk`.
- **Pinning:** `conda env export > environment.lock.yml` captures the exact
  package versions of a working environment.
