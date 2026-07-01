# Internal Technical Memorandum

Subject: Kaiser-Bessel Convolution Interpolation on Oversampled Fourier Grids

Purpose: Consolidated technical description of the oversampled-grid convolution policy used in image polarization, volume reprojection, 3D reconstruction, and class averaging.

## 1. Convolution Interpolation Framework

All interpolation operations are performed on the oversampled (padded) Fourier lattice. Logical Fourier coordinates are converted from native units to padded units using the oversampling factor pf.

x_pd = pf * x_orig

Interpolation weights are evaluated in padded logical units and sampling is performed using unit increments on the padded grid. The result of interpolation is written into the native (unpadded) target lattice.

General interpolation formula in padded logical coordinates:

F(x_pd) = sum_{k_pd in W} w(x_pd - k_pd) * F_pd(k_pd)

In 3D, the Kaiser-Bessel kernel remains separable:

w(x,y,z) = w(x) * w(y) * w(z)

### Key Parameters

- Oversampling factor pf = 2 (current configuration).
- Kernel width W (wdim): determines support size.
- Spectral parameter beta: controls concentration and stability.
- Amplitude scaling: pf^2 (2D) or pf^3 (3D).

## 2. Gather vs. Splat Duality under Oversampled Policy

Projection (gather):

f = sum w_pd(x_pd - k_pd) * F_pd(k_pd)

Reconstruction (splat):

F_native += w_pd(x_pd - k_pd) * f_pd

Both operations evaluate weights in padded logical units and operate on padded data samples. The target grid (polar or Cartesian) remains native.

## 3. Polarization of 2D Particle Images

Particle images are noise-normalized and Fourier transformed after real-space padding by pf=2. Polar sampling coordinates are converted into padded logical units prior to interpolation.

x_pd = pf * (r cos theta)

y_pd = pf * (r sin theta)

Interpolation is performed directly on the padded FFT lattice.

Amplitude correction:

Scale factor = pf^2

## 4. Polar Central Section Extraction from 3D Volumes

Volumes are padded in real space, Fourier transformed, and stored in expanded logical form. For each projection orientation R:

loc_pd = pf * (R * [h,k,0])

Interpolation weights are evaluated in padded units at loc_pd. Samples are gathered from the padded expanded Fourier volume.

Amplitude correction for padded 3D FFT:

Scale factor = pf^3

## 5. 3D Reconstruction (Plane Insertion)

Fourier planes are padded before insertion. Sampling from the padded plane uses indices (pf*h, pf*k).

comp = pwght * pf^2 * F_plane(pf*h, pf*k)

Non-uniform sampling location is computed in native units and converted to padded units:

loc_pd = pf * (R * [h,k,0])

KB weights are evaluated in padded logical units while splat updates are applied to native expanded volume indices.

Splat update: F_native(window) += comp * w_pd

## 6. Class Average Restoration

Class averaging follows the same oversampled-grid policy. Padded FFT samples are interpolated using padded-grid kernel weights and accumulated onto native class-average grids.

## 7. Scaling Summary

- Padded 2D FFT -> multiply by pf^2
- Padded 3D FFT -> multiply by pf^3
- Kernel geometry defined in padded logical units
- Native target grids remain unpadded

## 8. Summary of Policy Change

The previous strided policy evaluated kernels in native logical units and sampled padded data using stride-based parity selection. The updated policy evaluates kernels directly in padded logical units and performs interpolation using unit increments. This provides a conceptually cleaner, symmetric gather/splat formulation and aligns with standard oversampled-grid interpolation practice.

## 9. What Is Implemented In The Current Code

This section grounds the proposal above in the current SIMPLE implementation. The important correction is that SIMPLE does not call a generic NUFFT library. It implements Kaiser-Bessel convolution interpolation inside its own Fourier image, projector, polar Fourier, and reconstructor data structures.

### 9.1 Kaiser-Bessel Kernel

The KB kernel object is implemented in `src/main/interp/simple_kbinterpol.f90`.

- `kbinterpol%new` stores the half-width, oversampling factor, full width, beta parameter, and instrument-function threshold at lines 64-81.
- `kbinterpol%apod` evaluates the compact Kaiser-Bessel apodization function at lines 118-130.
- `kbinterpol%apod_mat_3d` builds a normalized separable 3D interpolation stencil at lines 203-235.
- `kbinterpol%instr` evaluates the instrument function used for gridding/deapodization correction at lines 293-308.

### 9.2 Reconstruction / Plane Insertion

The high-level reconstruction batch workflow is in `src/main/strategies/search/simple_matcher_3Drec.f90`.

- `calc_3Drec` initializes reconstruction objects, reads particle batches, prepares Fourier planes, inserts them into the 3D lattice, and writes partial reconstructions at lines 58-108.
- `prep_imgs4rec` normalizes, tapers, pads, FFTs each particle image, reads CTF parameters and shifts, and calls `gen_fplane4rec` to build the padded Fourier plane at lines 146-178.
- `update_rec` reads each particle orientation and forwards the prepared Fourier plane to the gridding path beginning at lines 180-188.

Even/odd half-map routing is explicit in `src/main/volume/simple_reconstructor_eo.f90`. `grid_plane` sends even particles to `even%insert_plane_oversamp` and odd particles to `odd%insert_plane_oversamp` at lines 384-395.

The actual 3D insertion is `src/main/volume/simple_reconstructor.f90::insert_plane_oversamp`, lines 216-359. This routine:

- builds symmetry-expanded rotation matrices at lines 236-244;
- maps padded Fourier-plane bounds back to native sample coordinates at lines 245-253;
- reads padded Fourier samples using `hp = h * OSMPL_PAD_FAC` and `kp = k * OSMPL_PAD_FAC`, with Friedel handling for `kp > 0`, at lines 273-285;
- computes the rotated 3D Fourier coordinate `loc` at lines 289-294;
- scales the complex Fourier-plane sample by `pf^2` at line 300;
- keeps CTF-squared density separately as `ctfval` at lines 301-302;
- evaluates normalized separable KB weights at lines 326-357;
- accumulates signal into `cmat_exp` and sampling/CTF density into `rho_exp` at lines 304-312.

After insertion, `compress_exp` copies the expanded nonuniform accumulation into the normal Fourier volume and density arrays at lines 522-559. Final sampling-density correction divides Fourier coefficients by `rho` in `sampl_dens_correct` at lines 500-520. The even/odd wrapper applies this correction before IFFT, clipping, magnitude correction, and map writing in `simple_reconstructor_eo.f90` lines 444-592.

### 9.3 Reprojection / Central-Section Extraction

The direct Cartesian reprojection path starts in `src/main/volume/simple_volinterp.f90::reproject`, lines 11-71. It pads the volume, FFTs it, expands the Fourier matrix with `projector%expand_cmat`, extracts one central section per orientation with `fproject_serial`, then IFFTs and clips each padded projection.

The reusable projector object is implemented in `src/main/image/simple_projector.f90`.

- `expand_cmat` requires an already-FFTed 3D volume, builds the KB object, creates the expanded cyclic Fourier matrix, and scales Fourier coefficients by the original box size at lines 41-93.
- `fproject` and `fproject_serial` rotate each 2D Fourier-plane coordinate into the 3D Fourier volume and call `interp_fcomp` at lines 123-191.
- `interp_fcomp` computes the local KB window and gathers the weighted sum from `cmat_exp` at lines 218-232.
- `interp_fcomp_oversamp` is an oversampled gather helper that converts the requested logical coordinate into padded units, evaluates KB weights on the padded lattice, gathers from the expanded padded grid, and applies `OSMPL_PAD_FAC^3` scaling at lines 193-215.

For refine3D reference-model materialization, the code usually works in polar Fourier space rather than first writing Cartesian reprojection images. `src/main/strategies/search/simple_matcher_refvol_utils.f90::read_mask_filter_reproject_refvols` reads, masks, filters, pads, FFTs, and expands the even/odd reference volumes, then calls `vol_pad2ref_pfts_opt` at lines 422-504. `src/main/pftc/simple_polarft_core.f90::vol_pad2ref_pfts_opt` calls the optimized batched polar Fourier extractor `fproject_polar_batch_opt` at lines 370-389. The non-optimized polar path calls `fproject_polar_batch` or `fproject_polar_batch_mirr` at lines 332-368.

### 9.4 Reprojection From A Reconstructor State

`src/main/volume/simple_reconstructor.f90::project_polar` can also project directly from a reconstructor's accumulated Fourier state. It expands the current compressed `cmat/rho` arrays into `cmat_exp/rho_exp`, loops over orientations and polar coordinates, interpolates both signal and density, and writes `pfts_state` and `ctf2_state` at lines 585-632. The helper functions `interp_cmat_exp` and `interp_rho_exp` use the same 3D KB matrix for signal and density interpolation at lines 634-659. The even/odd wrapper calls this for both halves in `simple_reconstructor_eo.f90` lines 431-441.

### 9.5 Gridding Correction

The gridding correction image or volume is built in `src/main/interp/simple_gridding.f90`.

- `prep2D_inv_instrfun4mul` builds a 2D inverse instrument-function image at lines 16-59.
- `prep3D_inv_instrfun4mul` builds the 3D equivalent at lines 65-107.

The 3D correction is used during distributed reconstruction assembly in `src/main/commanders/simple/simple_commanders_rec_distr.f90`: the module imports `prep3D_inv_instrfun4mul` at line 258, constructs `gridcorr_img` at lines 381-385, multiplies nonuniform source halves at lines 180-189, and multiplies the restored merged volume at lines 192-198.

### 9.6 Implications For An SGD Article Or Proposal

The current code already contains the numerical machinery needed for a projection/backprojection-style workflow:

- forward gather from a 3D Fourier volume to rotated 2D Cartesian or polar Fourier sections;
- splat/backprojection-like insertion from padded 2D Fourier planes into a 3D Fourier accumulation volume;
- separate CTF-squared/sampling-density accumulation through `rho_exp`;
- density correction, gridding correction, and even/odd half-map handling.

However, the current code does not expose this as a standalone differentiable SGD operator, and I did not find an explicit adjoint-consistency test around the KB projection/insertion pair. For SGD work, the next technical step is therefore not to re-invent KB interpolation, but to define and verify how residuals, CTF weighting, sampling-density correction, regularization, and mini-batch updates should be wrapped around the existing projection and insertion routines.
