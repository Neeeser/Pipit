# LocalVQE echo cancellation, vendored

LocalVQE is Apache-2.0. See `LICENSE-LocalVQE`. The ggml it runs on is MIT.
See `LICENSE-ggml`.

## Where this came from

`https://github.com/localai-org/LocalVQE`, commit
`f53063c9eb2a85f96479867d1dd911dc3bf6319b`. The files under `localvqe/` and
`include/` are its `ggml/` directory: the inference library without the CLI.

`https://github.com/ggml-org/ggml`, commit
`c044a8eeae2591faa0950c8b5e514cbc4bbfc4ca` (ggml 0.9.8). LocalVQE carries ggml
as a submodule at `ggml/vendor/ggml` and applies `ggml/patches/ggml-gru.patch`
to it at CMake configure time. The patch adds `GGML_OP_GRU` and `ggml_gru`, a
fused GRU scan that the graph depends on. The files under `ggml/` here are the
patched tree, so the patch is already in `ggml/include/ggml.h`,
`ggml/src/ggml.c`, `ggml/src/ggml-cpu/ggml-cpu.c`, `ggml/src/ggml-cpu/ops.cpp`
and `ggml/src/ggml-cpu/ops.h`. Nothing applies it at build time.

## Why it is vendored rather than depended on

Nobody publishes LocalVQE or ggml for SwiftPM. The upstream build is CMake,
which this repository does not otherwise need. Source rather than a prebuilt
binary, so what CI builds is what ships. The defines live in `Package.swift`,
not here.

## What was left out

From LocalVQE: `common.cpp`, `localvqe_model.cpp`, `native_engine.cpp`,
`audio_io.cpp`, the `gtcrn/` backend, the CLI, the benchmark, the tests and
the fuzzers. `LOCALVQE_HAS_GTCRN` is not defined, so `localvqe_api.cpp`
compiles without the GTCRN include. `localvqe_model.h` and `common.h` stay
because `localvqe_graph.h` and `daf_frontend.h` include them.

From ggml: every backend except the CPU one (`ggml-blas`, `ggml-metal`,
`ggml-cuda` and the rest), and inside `ggml-cpu/` the `amx/` kernels,
`hbm.cpp`, `kleidiai/`, `llamafile/`, `spacemit/`, `cpu-feats.cpp` and the
non-ARM `arch/` directories. `ggml-cpu.cpp` includes `amx/amx.h`
unconditionally, so that one header is present. Its declarations are behind
an x86 guard and compile to nothing on arm64.

`GGML_USE_BLAS` is not defined. ggml's own CMake turns it on by default on
macOS, which adds the `ggml-blas` backend as a second device. Pipit compiles
the CPU backend alone. `GGML_USE_ACCELERATE` is defined, as ggml's CMake does
on macOS, so the vector kernels in `ggml-cpu/vec.h` use vDSP.

## What was changed

Two edits, both in copied sources.

1. `ggml/src/ggml.cpp` is not present. Upstream that file holds one static
   initialiser, `ggml_uncaught_exception_init`, which installs a
   `std::set_terminate` handler that prints a backtrace. A vendored library
   should not replace the process-wide terminate handler at load time, so
   the file is dropped. Nothing else in it was referenced.

2. `localvqe/localvqe_graph.cpp`: `ensure_backends_loaded()` is a no-op.
   Upstream it calls `ggml_backend_load_all()` and then resolves the shared
   library's own path through `dladdr` and scans that directory for backend
   plug-ins. Pipit defines `GGML_USE_CPU`, so the registry in
   `ggml-backend-reg.cpp` registers the CPU backend when it is first used,
   and Pipit links no plug-ins. The function body is a comment that points
   here.

## Taking a newer version

Copy the file set above from the new LocalVQE commit and from the ggml
commit its submodule points at, with the GRU patch applied first. Reapply
the two edits. Compare `ggml/CMakeLists.txt` and `ggml/vendor/ggml/src/
ggml-cpu/CMakeLists.txt` against the defines in `Package.swift`, since a new
ggml can add a define the CPU backend needs. Then run `./scripts/build.sh
debug` and `./scripts/test.sh`. Check the numbers in the echo tests still
hold: the canceller's behaviour is measured, not assumed.
