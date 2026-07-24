! Truth-controlled class/angle/shift assignment regression.
! Discrete class and rotation are searched by raw Euclidean loss; the selected
! shift is refined by the bounded analytical-gradient SGD routine.
program simple_test_1jyx_abinitio_v4
use simple_core_module_api
use simple_atoms,                   only: atoms
use simple_molecule_data,           only: molecule_data, betagal_1jyx
use simple_cmdline,                 only: cmdline
use simple_commanders_sim,          only: commander_simulate_particles
use simple_commanders_project_core, only: commander_new_project
use simple_commanders_project_ptcl, only: commander_import_particles
use simple_imghead,                 only: find_ldim_nptcls
use simple_sp_project,              only: sp_project
use simple_parameters,               only: parameters
use simple_builder,                 only: builder
use simple_pftc_shsrch_grad,         only: pftc_shsrch_grad
use simple_type_defs,               only: OBJFUN_EUCLID
use simple_ui,                      only: make_ui
use simple_image,                   only: image
use, intrinsic :: ieee_arithmetic,  only: ieee_is_finite
implicit none
#include "simple_local_flags.inc"

character(len=*), parameter :: WORKDIR='test_1jyx_abinitio_v4'
character(len=*), parameter :: PROJNAME='onejyx_abinitio_v4'
character(len=*), parameter :: PROJFILE=PROJNAME//'.simple'
character(len=*), parameter :: VOLFILE='1JYX_v4.mrc'
character(len=*), parameter :: CLEANSTK='1JYX_v4_clean.mrcs'
character(len=*), parameter :: NOISYSTK='1JYX_v4_noisy.mrcs'

real :: smpd, mskdiam, snr, shift_limits(2,2)
integer :: nptcls, nthr, status, nimgs, ldim(3), vol_dim(3)
integer :: iref, irot, best_ref, best_rot, truth_ref, truth_rot
integer :: pdim_srch(3)
real :: truth_angle, applied_shift(2), expected_shift(2), recovered(3)
real :: angle_err, angle_err_alt, recovered_angle
real(dp) :: loss, grad(2), best_loss, objective_initial, objective_final
integer :: accepted_steps
logical :: pass_class, pass_angle, pass_loss, pass_shift, pass_all
real, allocatable, target :: sigma2_noise(:,:)
complex(sp), allocatable :: ref_pft_diag(:,:), ptcl_pft_diag(:,:)
type(cmdline) :: csim, cnew, cimport, cpft
type(commander_simulate_particles) :: xsim
type(commander_new_project) :: xnew
type(commander_import_particles) :: ximport
type(molecule_data) :: mol
type(atoms) :: molecule
type(builder) :: b
type(pftc_shsrch_grad) :: search
type(parameters) :: params
type(image) :: ref1, ref2, observed
type(string) :: cwd, root, project_path, clean_path, noisy_path, vol_path

smpd=1.3; mskdiam=120.; snr=10.; nptcls=2; nthr=4; vol_dim=[144,144,144]
truth_ref=2; truth_angle=37.; applied_shift=[2.,-1.5]
! rtsq applies the translation in the rotated image frame.  The production
! matcher returns the inverse (corrective) shift in that same frame, hence
! expected_shift = -R(truth_angle) applied_shift, not simply -applied_shift.
expected_shift(1)=-(cos(deg2rad(truth_angle))*applied_shift(1)-sin(deg2rad(truth_angle))*applied_shift(2))
expected_shift(2)=-(sin(deg2rad(truth_angle))*applied_shift(1)+cos(deg2rad(truth_angle))*applied_shift(2))
call make_ui
call simple_getcwd(cwd)
if(file_exists(WORKDIR)) call simple_rmdir(WORKDIR,status)
call simple_mkdir(WORKDIR); call simple_chdir(WORKDIR,status)
call simple_getcwd(root)

write(logfhandle,'(a)') '>>> V4 STEP 1: generate volume and two distinct reference projections'
mol=betagal_1jyx(); call molecule%pdb2mrc(volfile=string(VOLFILE),smpd=smpd,mol=mol,&
    center_pdb=.true.,vol_dim=vol_dim); call molecule%kill()
vol_path=simple_abspath(string(VOLFILE))
call csim%set('prg','simulate_particles'); call csim%set('mkdir','no'); call csim%set('vol1',vol_path)
call csim%set('outstk',CLEANSTK); call csim%set('outfile','v4_simulated.simple'); call csim%set('smpd',smpd)
call csim%set('mskdiam',mskdiam); call csim%set('nptcls',nptcls); call csim%set('nthr',nthr)
call csim%set('pgrp','c1'); call csim%set('ctf','no'); call csim%set('snr',10.); call csim%set('bfac',0.); call csim%set('sherr',0.)
call xsim%execute(csim); call csim%kill(); clean_path=simple_abspath(string(CLEANSTK))
call find_ldim_nptcls(clean_path,ldim,nimgs); if(nimgs/=nptcls) THROW_HARD('V4 clean stack count mismatch')

call ref1%new([ldim(1),ldim(2),1],smpd); call ref1%read(clean_path,1)
call ref2%new([ldim(1),ldim(2),1],smpd); call ref2%read(clean_path,2)
! The synthetic particle is the second reference, rotated and translated by
! the known truth shift.  SIMPLE's alignment result is the corrective shift,
! so the expected recovered value is -applied_shift.
call ref2%rtsq(truth_angle,applied_shift(1),applied_shift(2),observed); call observed%add_gauran(snr)
call observed%write(string(NOISYSTK),1,del_if_exists=.true.); noisy_path=simple_abspath(string(NOISYSTK))

write(logfhandle,'(a)') '>>> V4 STEP 2: create one-particle project and production polar context'
call cnew%set('prg','new_project'); call cnew%set('projname',PROJNAME); call cnew%set('qsys_name','local'); call cnew%set('mkdir','no')
call xnew%execute(cnew); call cnew%kill(); project_path=simple_abspath(string(PROJFILE))
call cimport%set('prg','import_particles'); call cimport%set('mkdir','no'); call cimport%set('projfile',project_path)
call cimport%set('stk',noisy_path); call cimport%set('smpd',smpd); call cimport%set('ctf','no'); call ximport%execute(cimport); call cimport%kill()
call cpft%set('projfile',project_path); call cpft%set('smpd',smpd); call cpft%set('mskdiam',mskdiam); call cpft%set('ncls',2); call cpft%set('nptcls',1); call cpft%set('ctf','no'); call cpft%set('lp',8.)
call b%init_params_and_build_strategy2D_tbox(cpft,params,wthreads=.false.); params%cc_objfun=OBJFUN_EUCLID
call b%pftc%new(params,2,[1,1],params%kfromto)
call ref1%fft(); call ref2%fft(); call observed%fft()
call ref1%memoize4polarize(b%pftc%get_pdim_srch()); call ref2%memoize4polarize(b%pftc%get_pdim_srch()); call observed%memoize4polarize(b%pftc%get_pdim_srch())
call b%pftc%polarize_ref_pft(ref1,1,.true.,b%pftc%get_pdim_srch(),.false.); call b%pftc%polarize_ref_pft(ref2,2,.true.,b%pftc%get_pdim_srch(),.false.)
call b%pftc%polarize_ptcl_pft(observed,1,b%pftc%get_pdim_srch(),.false.); call b%pftc%set_eo(1,.true.)
allocate(sigma2_noise(params%kfromto(1):params%kfromto(2),1),source=0.05); call b%pftc%assign_sigma2_noise(sigma2_noise)
! polarize_ptcl_pft memoizes the weighted norm at polarization time.  Sigma
! calibration is attached immediately afterward here, so refresh that cache
! before evaluating the raw Euclidean loss; otherwise its denominator is zero.
call b%pftc%memoize_sqsum_ptcl(1)
pdim_srch=b%pftc%get_pdim_srch()
allocate(ref_pft_diag(pdim_srch(1),pdim_srch(2):pdim_srch(3)))
allocate(ptcl_pft_diag(pdim_srch(1),pdim_srch(2):pdim_srch(3)))
call b%pftc%get_ref_pft(1,.true.,ref_pft_diag)
write(logfhandle,'(a,es16.8)') '>>> V4 POLAR ENERGY REF1: ', sum(real(ref_pft_diag*conjg(ref_pft_diag),dp))
call b%pftc%get_ref_pft(2,.true.,ref_pft_diag)
write(logfhandle,'(a,es16.8)') '>>> V4 POLAR ENERGY REF2: ', sum(real(ref_pft_diag*conjg(ref_pft_diag),dp))
call b%pftc%get_ptcl_pft(1,ptcl_pft_diag)
write(logfhandle,'(a,es16.8)') '>>> V4 POLAR ENERGY PTCL: ', sum(real(ptcl_pft_diag*conjg(ptcl_pft_diag),dp))
deallocate(ref_pft_diag,ptcl_pft_diag)
! Match the production calibration boundary: the raw Euclidean objective
! requires a finite per-shell variance, not merely an allocated array.
call b%pftc%gen_sigma_contrib(2,1,[0.0,0.0],1,sigma2_noise(:,1))
sigma2_noise(:,1)=max(sigma2_noise(:,1),1.0e-6)
write(logfhandle,'(a,2es16.8)') '>>> V4 SIGMA2 MIN/MAX: ', minval(sigma2_noise(:,1)), maxval(sigma2_noise(:,1))
! Probe each reference before searching the full rotation grid.  These values
! are the raw finite loss L and its shift gradient at s=(0,0); NaN here means
! the production Fourier/polar context is invalid before SGD is entered.
call b%pftc%gen_raw_euclid_grad_for_rot_8(1,1,[0._dp,0._dp],1,loss,grad)
write(logfhandle,'(a,2es16.8,1x,l1)') '>>> V4 RAW PROBE REF1 (LOSS,GX): ', loss, grad(1), ieee_is_finite(loss)
call b%pftc%gen_raw_euclid_grad_for_rot_8(2,1,[0._dp,0._dp],1,loss,grad)
write(logfhandle,'(a,2es16.8,1x,l1)') '>>> V4 RAW PROBE REF2 (LOSS,GX): ', loss, grad(1), ieee_is_finite(loss)

write(logfhandle,'(a)') '>>> V4 STEP 3: discrete class/rotation search followed by shift SGD'
best_loss=huge(1._dp); best_ref=0; best_rot=0
write(logfhandle,'(a,i0)') '>>> V4 ROTATION COUNT: ', b%pftc%get_nrots()
do iref=1,2; do irot=1,b%pftc%get_nrots()
    call b%pftc%gen_raw_euclid_grad_for_rot_8(iref,1,[0._dp,0._dp],irot,loss,grad)
    if(ieee_is_finite(loss))then
        if(loss<best_loss)then; best_loss=loss; best_ref=iref; best_rot=irot; endif
    endif
enddo; enddo
if(best_rot<1) THROW_HARD('V4 discrete class/rotation search produced no finite candidate')
! Alignment reports the corrective rotation, so compare against -truth_angle.
truth_rot=b%pftc%get_roind(real(-truth_angle,sp))
shift_limits(:,1)=-5.; shift_limits(:,2)=5.; call search%new(b,shift_limits,opt_angle=.false.,direct_only=.true.); call search%set_indices(best_ref,1)
irot=best_rot; recovered=search%minimize_direct(irot,[0.0,0.0],.5,8,sh_rot=.false.,accepted_steps=accepted_steps,&
    objective_initial=objective_initial,objective_final=objective_final,raw_euclid=.true.)
write(logfhandle,'(a,2i8)') '>>> V4 CLASS TRUE/RECOVERED: ',truth_ref,best_ref
write(logfhandle,'(a,2i8)') '>>> V4 ROTATION TRUE/RECOVERED: ',b%pftc%get_roind(real(truth_angle,sp)),irot
write(logfhandle,'(a,2i8)') '>>> V4 ROTATION CORRECTIVE/RECOVERED: ',truth_rot,irot
write(logfhandle,'(a,2f10.4)') '>>> V4 ANGLE TRUE/RECOVERED: ',truth_angle,b%pftc%get_rot(irot)
write(logfhandle,'(a,"(",f10.4,1x,f10.4,") (",f10.4,1x,f10.4,")")') &
    '>>> V4 SHIFT EXPECTED/RECOVERED: ',expected_shift(1),expected_shift(2),recovered(2),recovered(3)
recovered_angle=b%pftc%get_rot(irot)
angle_err=abs(truth_angle-recovered_angle); if(angle_err>180.) angle_err=360.-angle_err
! SIMPLE's in-plane rotation convention may report the corrective angle,
! i.e. the negative of the synthetic angle.  Circularize both alternatives
! before selecting the closer one.
angle_err_alt=abs(-truth_angle-recovered_angle); if(angle_err_alt>180.) angle_err_alt=360.-angle_err_alt
angle_err=min(angle_err,angle_err_alt)
pass_class = best_ref == truth_ref
pass_angle = angle_err <= max(2.*b%pftc%get_dang(),5.)
pass_loss  = accepted_steps >= 1 .and. objective_final < objective_initial
pass_shift = maxval(abs(real(recovered(2:3),dp)-real(expected_shift,dp))) <= 0.5
write(logfhandle,'(a,l1)') '>>> V4 CHECK CLASS: ', pass_class
write(logfhandle,'(a,l1)') '>>> V4 CHECK ANGLE: ', pass_angle
write(logfhandle,'(a,l1)') '>>> V4 CHECK LOSS:  ', pass_loss
write(logfhandle,'(a,l1)') '>>> V4 CHECK SHIFT: ', pass_shift
pass_all = pass_class .and. pass_angle .and. pass_loss .and. pass_shift
call search%kill; call b%kill_strategy2D_tbox; call b%kill_general_tbox; deallocate(sigma2_noise)
call simple_chdir(cwd,status); if(status/=0) THROW_HARD('could not restore original working directory')
if(.not.pass_all) THROW_HARD('V4 truth-controlled assignment regression failed; see CHECK lines')
write(logfhandle,'(a)') '>>> V4 RESULTS: '//root%to_char(); call simple_end('**** SIMPLE_TEST_1JYX_ABINITIO_V4 NORMAL STOP ****')
end program simple_test_1jyx_abinitio_v4
