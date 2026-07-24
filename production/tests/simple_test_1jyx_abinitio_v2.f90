! Standalone end-to-end test for a simulated single-particle workflow.
! tmux new -As work
!
! src=/usr/local/data/mazhar/Projects/SIMPLE
! bld=/usr/local/data/mazhar/Projects/SIMPLE_joint2d_sgd_build
! cd "$src" && git pull --ff-only
!
! rm -rf "$bld" && mkdir -p "$bld" && cd "$bld"
!
! module load gcc/15.2.0
! cmake -S "$src" -DUSE_OPENMP_OFFLOAD=OFF -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=debug
! make -j"$(nproc)" install
! export SIMPLE_PATH="$bld"
! export PATH="$SIMPLE_PATH/bin:$SIMPLE_PATH/scripts:$PATH"
!
! rm -rf ~/Projects/simple_test_1jyx_abinitio_v2 && mkdir -p ~/Projects/simple_test_1jyx_abinitio_v2 && cd ~/Projects/simple_test_1jyx_abinitio_v2
! simple_test_joint2D_direct_shift 2>&1 | tee simple_test_joint2D_direct_shift.log
! simple_test_1jyx_abinitio_v2 2>&1 | tee simple_test_1jyx_abinitio_v2.log
! 
! ======== Rebuild path =============================================
! cmake --build "$bld/build-debug" --target simple_test_1jyx_abinitio_v2 simple_test_joint2D_direct_shift --parallel 48 2>&1 | tee "$bld/build-debug/build.log"
! cd ~/Projects/simple_test_1jyx_abinitio_v2
! "$bld/build-debug/production/simple_test_joint2D_direct_shift" 2>&1 | tee direct_shift.log
! "$bld/build-debug/production/simple_test_1jyx_abinitio_v2" 2>&1 | tee abinitio_v2.log
! 
program simple_test_1jyx_abinitio_v2
use simple_core_module_api
use simple_atoms,                    only: atoms
use simple_molecule_data,            only: molecule_data, betagal_1jyx
use simple_cmdline,                  only: cmdline
use simple_commanders_sim,           only: commander_simulate_particles
use simple_commanders_project_core,  only: commander_new_project
use simple_commanders_project_ptcl,  only: commander_import_particles
use simple_commanders_abinitio2D,    only: commander_abinitio2D
use simple_commanders_abinitio,      only: commander_abinitio3D
use simple_procimgstk,               only: add_noise_imgfile
use simple_imghead,                  only: find_ldim_nptcls
use simple_sp_project,               only: sp_project
use simple_pftc_srch_api
use simple_builder,                  only: builder
use simple_pftc_shsrch_grad,         only: pftc_shsrch_grad
use simple_type_defs,                only: OBJFUN_EUCLID
use simple_ui,                       only: make_ui
use simple_image,                    only: image
use, intrinsic :: ieee_arithmetic,    only: ieee_is_finite
implicit none
#include "simple_local_flags.inc"

character(len=*), parameter :: WORKDIR    = 'test_1jyx_abinitio'
character(len=*), parameter :: PROJNAME   = 'onejyx_abinitio'
character(len=*), parameter :: PROJFILE   = PROJNAME//'.simple'
character(len=*), parameter :: VOL_FILE   = '1JYX.mrc'
character(len=*), parameter :: CLEAN_FILE = '1JYX_particles_clean.mrcs'
character(len=*), parameter :: NOISY_FILE = '1JYX_particles_noisy.mrcs'
character(len=*), parameter :: ORI_FILE   = '1JYX_particles_oris.txt'

real    :: smpd, mskdiam, noise_snr
integer :: nptcls, ncls, nthr
type(cmdline) :: user_args, cline_sim, cline_new_project, cline_import
type(cmdline) :: cline_abinitio2D, cline_abinitio3D
type(commander_simulate_particles) :: xsimulate_particles
type(commander_new_project)        :: xnew_project
type(commander_import_particles)   :: ximport_particles
type(commander_abinitio2D)         :: xabinitio2D
type(commander_abinitio3D)         :: xabinitio3D
type(molecule_data)                :: mol
type(atoms)                        :: molecule
type(sp_project)                   :: spproj
type(parameters)                   :: pft_params
type(builder)                      :: pft_builder
type(pftc_shsrch_grad)             :: direct_shift_search
type(string) :: original_cwd, workflow_root, project_root, project_path
type(string) :: volume_path, clean_path, noisy_path, orientations_path
type(cmdline) :: cline_pft
integer      :: ldim(3), nimgs, status
integer      :: vol_dim(3)
integer      :: pdim_srch(3), direct_irot, direct_accepted
real         :: shift_limits(2,2), direct_cxy(3)
real(dp)     :: objective_initial, objective_final
real(dp)     :: raw_f, raw_grad(2), raw_f_xp, raw_f_xm, raw_f_yp, raw_f_ym
real(dp)     :: ref_pft_energy, ptcl_pft_energy, sigma_min, sigma_max
complex(sp), allocatable :: ref_pft_diag(:,:), ptcl_pft_diag(:,:)
real, allocatable :: ref_rmat_diag(:,:,:), ptcl_rmat_diag(:,:,:)
real, allocatable, target :: sigma2_noise(:,:)

type :: alignment_truth
    integer :: class_id
    integer :: rotation_index
    real    :: angle_deg
    real    :: shift(2)
end type alignment_truth
type(alignment_truth) :: truth
type(image) :: reference, observed, corrected

! Defaults keep the test reasonably small while leaving enough particles for
! both classifications.  They can be overridden with old-style key=value args.
smpd      = 1.3
mskdiam   = 180.0
noise_snr = 10.0
nptcls    = 200
ncls      = 4
nthr      = 4
vol_dim   = [144, 144, 144]
truth%class_id       = 1
truth%rotation_index = 1
truth%angle_deg      = 0.0
truth%shift          = [2.0, 0.0]

if( command_argument_count() > 0 )then
    call user_args%parse_oldschool
    if( user_args%defined('smpd')     ) smpd      = user_args%get_rarg('smpd')
    if( user_args%defined('mskdiam')  ) mskdiam   = user_args%get_rarg('mskdiam')
    if( user_args%defined('snr')      ) noise_snr = user_args%get_rarg('snr')
    if( user_args%defined('nptcls')   ) nptcls    = user_args%get_iarg('nptcls')
    if( user_args%defined('ncls')     ) ncls      = user_args%get_iarg('ncls')
    if( user_args%defined('nthr')     ) nthr      = user_args%get_iarg('nthr')
endif
if( smpd <= 0.0 )      THROW_HARD('smpd must be positive')
if( mskdiam <= 0.0 )   THROW_HARD('mskdiam must be positive')
if( noise_snr <= 0.0 ) THROW_HARD('snr must be positive')
if( nptcls < 8 )       THROW_HARD('nptcls must be at least 8')
if( ncls < 1 .or. ncls >= nptcls ) THROW_HARD('ncls must be in [1,nptcls)')
if( nthr < 1 )         THROW_HARD('nthr must be positive')

! Direct commander calls need the normal SIMPLE UI metadata for mkdir=yes.
call make_ui
call simple_getcwd(original_cwd)
if( file_exists(WORKDIR) )then
    call simple_rmdir(WORKDIR, status)
    if( status /= 0 ) THROW_HARD('could not reset '//WORKDIR)
endif
call simple_mkdir(WORKDIR)
call simple_chdir(WORKDIR, status)
if( status /= 0 ) THROW_HARD('could not enter '//WORKDIR)
call simple_getcwd(workflow_root)

write(logfhandle,'(a)') '>>> Step 1/6: generate a volume from embedded 1JYX beta-galactosidase coordinates'
mol = betagal_1jyx()
write(logfhandle,'(A,3I6)') '>>> TEST EXPLICIT VOLUME DIMENSIONS: ', vol_dim
call molecule%pdb2mrc(volfile=string(VOL_FILE), smpd=smpd, mol=mol, center_pdb=.true., vol_dim=vol_dim)
call molecule%kill()
volume_path = simple_abspath(string(VOL_FILE))
call find_ldim_nptcls(volume_path, ldim, nimgs)
if( any(ldim < 1) .or. ldim(3) <= 1 ) THROW_HARD('1JYX volume has invalid dimensions')

write(logfhandle,'(a)') '>>> Step 2/6: simulate a clean stack at random orientations'
call cline_sim%set('prg',        'simulate_particles')
call cline_sim%set('mkdir',                       'no')
call cline_sim%set('vol1',                volume_path)
call cline_sim%set('outstk',               CLEAN_FILE)
call cline_sim%set('outfile',                 ORI_FILE)
call cline_sim%set('smpd',                       smpd)
call cline_sim%set('mskdiam',                 mskdiam)
call cline_sim%set('nptcls',                   nptcls)
call cline_sim%set('nthr',                       nthr)
call cline_sim%set('pgrp',                       'c1')
call cline_sim%set('ctf',                         'no')
call cline_sim%set('snr',                         10.0) ! simimg adds no noise for SNR >= 5
call cline_sim%set('bfac',                          0.0)
call cline_sim%set('sherr',                        0.0)
call xsimulate_particles%execute(cline_sim)
call cline_sim%kill()
clean_path        = simple_abspath(string(CLEAN_FILE))
orientations_path = simple_abspath(string(ORI_FILE))
call find_ldim_nptcls(clean_path, ldim, nimgs)
if( nimgs /= nptcls ) THROW_HARD('clean simulated stack has the wrong particle count')

write(logfhandle,'(a)') '>>> Step 3/6: apply rotate by known angle and shift by known (sx, sy)'
call reference%new([ldim(1), ldim(2), 1], smpd)
call reference%read(string(CLEAN_FILE), 1)

! Generate shifted particle
call reference%rtsq(0.0, &
                    truth%shift(1), &
                    truth%shift(2), &
                    observed)

write(logfhandle,'(a,f7.3)') '>>> Step 4/6: add Gaussian noise to the stack; SNR = ', noise_snr
! Add noise to this one image
call observed%add_gauran(noise_snr)

! Materialize exactly the particle that the production workflow would import.
! Keeping this one-image stack separate from the original simulated stack is
! important: the direct test must exercise the same stack/project ownership
! rules as abinitio2D without launching the full multi-class experiment.
call observed%write(string(NOISY_FILE), 1, del_if_exists=.true.)
call find_ldim_nptcls(string(NOISY_FILE), ldim, nimgs)
if( nimgs /= 1 ) THROW_HARD('materialized synthetic stack has the wrong particle count')
noisy_path = simple_abspath(string(NOISY_FILE))

! Optional manual correction for inspection
call observed%rtsq(0.0, &
                   -truth%shift(1), &
                   -truth%shift(2), &
                   corrected)

write(logfhandle,'(a)') '>>> Step 5/6: prepare one-particle project and production Fourier/polar context'

! This is the same preparation boundary used by abinitio2D: create a SIMPLE
! project, import the particle stack, and let the builder read the project
! metadata before constructing the 2D toolbox.  We intentionally stop before
! commander_abinitio2D; a later v3 test will cover the complete classification.
call cline_new_project%set('prg',      'new_project')
call cline_new_project%set('projname',  PROJNAME)
call cline_new_project%set('qsys_name', 'local')
call cline_new_project%set('mkdir',     'no')
call xnew_project%execute(cline_new_project)
call cline_new_project%kill()
call simple_getcwd(project_root)
project_path = simple_abspath(string(PROJFILE))

call cline_import%set('prg',     'import_particles')
call cline_import%set('mkdir',   'no')
call cline_import%set('projfile', project_path)
call cline_import%set('stk',      noisy_path)
call cline_import%set('smpd',     smpd)
call cline_import%set('ctf',      'no')
call ximport_particles%execute(cline_import)
call cline_import%kill()

write(logfhandle,'(a)') '>>> Step 6/6: invoke the production Fourier/polar direct shift gradient'
call cline_pft%set('projfile', project_path)
call cline_pft%set('smpd',    smpd)
call cline_pft%set('mskdiam', mskdiam)
call cline_pft%set('ncls',    1)
call cline_pft%set('nptcls',  1)
call cline_pft%set('ctf',     'no')
call cline_pft%set('lp',      8.0)
call pft_builder%init_params_and_build_strategy2D_tbox(cline_pft, pft_params, wthreads=.false.)
pft_params%cc_objfun = OBJFUN_EUCLID
call pft_builder%pftc%new(pft_params, 1, [1,1], pft_params%kfromto)
! The production workflow normally attaches this calibration through
! simple_euclid_sigma2.  This standalone synthetic test constructs the
! polar calculator directly, so provide a finite positive variance for
! every Fourier shell and the one test particle before evaluating NLL.
allocate(sigma2_noise(pft_params%kfromto(1):pft_params%kfromto(2),1), source=1.0)
call pft_builder%pftc%assign_sigma2_noise(sigma2_noise)
pdim_srch = pft_builder%pftc%get_pdim_srch()
! Match SIMPLE's production image-to-polar workflow: polarize reads the
! image Fourier buffer, so explicitly FFT both synthetic spatial images first.
! Capture spatial energies before FFT; ordinary image has no get_sumsq method.
ref_rmat_diag  = reference%get_rmat()
ptcl_rmat_diag = observed%get_rmat()
write(logfhandle,'(a,2es16.8)') '>>> DIAG IMAGE SUMSQ REF/OBS: ', &
    sum(real(ref_rmat_diag,dp)**2), sum(real(ptcl_rmat_diag,dp)**2)
deallocate(ref_rmat_diag, ptcl_rmat_diag)
call reference%fft()
call observed%fft()
call pft_builder%pftc%polarize_ref_pft(reference, 1, iseven=.true., pdim=pdim_srch, oversamp=.false.)
call pft_builder%pftc%polarize_ptcl_pft(observed, 1, pdim=pdim_srch, oversamp=.false.)
call pft_builder%pftc%set_eo(1, .true.)

! DIAGNOSTIC BLOCK (temporary, P1): prove that the production context contains
! nonzero reference/particle Fourier data before the optimizer is called.
! A zero norm here means the failure is in image FFT/polarization or project
! indexing, not in the SGD step rule.
allocate(ref_pft_diag(pdim_srch(1),pdim_srch(2):pdim_srch(3)))
allocate(ptcl_pft_diag(pdim_srch(1),pdim_srch(2):pdim_srch(3)))
call pft_builder%pftc%get_ref_pft(1, .true., ref_pft_diag)
call pft_builder%pftc%get_ptcl_pft(1, ptcl_pft_diag)
ref_pft_energy   = sum(real(ref_pft_diag * conjg(ref_pft_diag),dp))
ptcl_pft_energy  = sum(real(ptcl_pft_diag * conjg(ptcl_pft_diag),dp))
write(logfhandle,'(a,3I8)')    '>>> DIAG POLAR DIMENSIONS: ', pdim_srch
write(logfhandle,'(a,es16.8)') '>>> DIAG POLAR ENERGY REF: ', ref_pft_energy
write(logfhandle,'(a,es16.8)') '>>> DIAG POLAR ENERGY PTCL: ', ptcl_pft_energy
write(logfhandle,'(a,2es16.8)') '>>> DIAG POLAR ABS MAX REF/PTCL: ', maxval(abs(ref_pft_diag)), maxval(abs(ptcl_pft_diag))

! P1: calibrate each Fourier shell with the production convention
! sigma2(k)=sum_p|R-P|^2/(2*pftsz), then keep the existing Euclidean score.
call pft_builder%pftc%gen_sigma_contrib(1, 1, [0.0, 0.0], 1, sigma2_noise(:,1))
sigma_min = minval(sigma2_noise(:,1))
sigma_max = maxval(sigma2_noise(:,1))
write(logfhandle,'(a,es16.8)') '>>> DIAG SIGMA2 MIN: ', sigma_min
write(logfhandle,'(a,es16.8)') '>>> DIAG SIGMA2 MAX: ', sigma_max
sigma2_noise(:,1) = max(sigma2_noise(:,1), 1.0e-6)

! DIAGNOSTIC BLOCK (temporary, P2): evaluate the finite raw loss and gradient
! at the origin and at four small probes.  This distinguishes a genuinely
! flat objective from a zero/invalid normalization before minimize_direct.
call pft_builder%pftc%gen_raw_euclid_grad_for_rot_8(1, 1, [0.0_dp,0.0_dp], 1, raw_f, raw_grad)
call pft_builder%pftc%gen_raw_euclid_grad_for_rot_8(1, 1, [ 1.0_dp,0.0_dp], 1, raw_f_xp, raw_grad)
call pft_builder%pftc%gen_raw_euclid_grad_for_rot_8(1, 1, [-1.0_dp,0.0_dp], 1, raw_f_xm, raw_grad)
call pft_builder%pftc%gen_raw_euclid_grad_for_rot_8(1, 1, [0.0_dp, 1.0_dp], 1, raw_f_yp, raw_grad)
call pft_builder%pftc%gen_raw_euclid_grad_for_rot_8(1, 1, [0.0_dp,-1.0_dp], 1, raw_f_ym, raw_grad)
write(logfhandle,'(a,es16.8,1x,2es16.8)') '>>> DIAG RAW AT ZERO (LOSS,GX,GY): ', raw_f, raw_grad
write(logfhandle,'(a,4es16.8)') '>>> DIAG RAW PROBES (+X,-X,+Y,-Y): ', raw_f_xp, raw_f_xm, raw_f_yp, raw_f_ym

shift_limits(:,1) = -5.0
shift_limits(:,2) =  5.0
call direct_shift_search%new(pft_builder, shift_limits, opt_angle=.false., direct_only=.true.)
call direct_shift_search%set_indices(1, 1)
direct_irot = 1
! P2: request the finite raw Euclidean loss/gradient API so SGD does not
! differentiate the underflow-prone exp(-L) score.
direct_cxy = direct_shift_search%minimize_direct( &
    direct_irot, [0.0, 0.0], 0.5, 5, sh_rot=.false., accepted_steps=direct_accepted, &
    objective_initial=objective_initial, objective_final=objective_final, raw_euclid=.true.)
write(logfhandle,'(a,es14.6)') '>>> DIRECT SHIFT OBJECTIVE INITIAL: ', objective_initial
write(logfhandle,'(a,es14.6)') '>>> DIRECT SHIFT OBJECTIVE FINAL:   ', objective_final
write(logfhandle,'(a,i0)')     '>>> DIRECT SHIFT ACCEPTED STEPS: ', direct_accepted
if( direct_irot == 0 ) THROW_HARD('direct shift search rejected every tested state')
if( .not. ieee_is_finite(real(direct_cxy(1),dp)) ) THROW_HARD('direct shift objective is nonfinite')
write(logfhandle,'(a,2f10.4)') '>>> DIRECT SHIFT RECOVERED: ', direct_cxy(2:3)
call direct_shift_search%kill
call pft_builder%kill_strategy2D_tbox
call pft_builder%kill_general_tbox
deallocate(sigma2_noise)
deallocate(ref_pft_diag, ptcl_pft_diag)

write(logfhandle,'(A,2F10.4)') &
    '>>> SYNTHETIC APPLIED SHIFT: ', truth%shift
write(logfhandle,'(A,2F10.4)') &
    '>>> EXPECTED CORRECTIVE SHIFT: ', -truth%shift

! noisy_path = simple_abspath(string(NOISY_FILE))
! call image_out%rtsq(clean_path, angle, shift_x, shift_y, noisy_path)
! call find_ldim_nptcls(noisy_path, ldim, nimgs)
! if( nimgs /= nptcls ) THROW_HARD('rotated simulated stack has the wrong particle count')

! write(logfhandle,'(a,f7.3)') '>>> Step 4/6: add Gaussian noise to the stack; SNR = ', noise_snr
! call add_noise_imgfile(noisy_path, noisy_path, noise_snr, smpd)
! call find_ldim_nptcls(noisy_path, ldim, nimgs)
! if( nimgs /= nptcls ) THROW_HARD('noisy simulated stack has the wrong particle count')

! write(logfhandle,'(a)') '>>> Step 5/6: create a SIMPLE project and import the noisy particles'
! call cline_new_project%set('prg',          'new_project')
! call cline_new_project%set('projname',          PROJNAME)
! call cline_new_project%set('qsys_name',          'local')
! call xnew_project%execute(cline_new_project)
! call cline_new_project%kill()
! call simple_getcwd(project_root)
! project_path = simple_abspath(string(PROJFILE))
! call cline_import%set('prg',               'import_particles')
! call cline_import%set('mkdir',                           'no')
! call cline_import%set('projfile',                project_path)
! call cline_import%set('stk',                       noisy_path)
! call cline_import%set('oritab',             orientations_path)
! call cline_import%set('smpd',                            smpd)
! call cline_import%set('ctf',                             'no')
! call ximport_particles%execute(cline_import)
! call cline_import%kill()

! write(logfhandle,'(a)') '>>> Step 6/6: run ab initio 2D classification'
! call cline_abinitio2D%set('prg',          'abinitio2D')
! call cline_abinitio2D%set('projfile',     project_path)
! call cline_abinitio2D%set('mkdir',               'yes')
! call cline_abinitio2D%set('mskdiam',           mskdiam)
! call cline_abinitio2D%set('ncls',                 ncls)
! call cline_abinitio2D%set('nstages',                 1)
! call cline_abinitio2D%set('nits_per_stage',          1)
! call cline_abinitio2D%set('nthr',                 nthr)
! call xabinitio2D%execute(cline_abinitio2D)
! call cline_abinitio2D%kill()
! call capture_stage_project('abinitio2D')
! call spproj%read(project_path)
! if( spproj%os_cls2D%get_noris() < 1 ) THROW_HARD('abinitio2D produced no class averages')
! call spproj%kill()

! call simple_chdir(original_cwd, status)
! if( status /= 0 ) THROW_HARD('could not restore the original working directory')
write(logfhandle,'(a)') '>>> Step 6/6: report synthetic alignment setup (full abinitio2D deferred to v3)'
write(logfhandle,'(a)') '>>> Results: '//workflow_root%to_char()
call simple_end('**** SIMPLE_TEST_1JYX_ABINITIO_V2 NORMAL STOP ****')

contains

    subroutine capture_stage_project( stage )
        character(len=*), intent(in) :: stage
        if( file_exists(PROJFILE) ) project_path = simple_abspath(string(PROJFILE))
        call simple_chdir(project_root, status)
        if( status /= 0 ) THROW_HARD('could not leave the '//trim(stage)//' directory')
    end subroutine capture_stage_project

end program simple_test_1jyx_abinitio_v2
