# Commander1
Unreleased Commander 1

For running on the ITA cluster using the latest compilers, set
`COMMANDER=ita_ifx` in your environment

Note that the `HEALPix` and `cfitsio` libraries are currently installed in `/mn/stornext/u3/duncanwa/Commander/build_owl3637_oneapi_Release`. This subject to change, so be aware that these lines may need to be changed in `config/config.ita_ifx`.

`module load intel/oneapi compiler/latest mpi/latest mkl/latest` should also be called before running `make`.
