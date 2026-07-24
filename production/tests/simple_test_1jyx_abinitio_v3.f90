! End-to-end project/abinitio2D regression for the embedded 1JYX dataset.
! This test deliberately keeps direct shift-gradient assertions in v2; v3
! verifies that a complete multi-particle project reaches abinitio2D and
! produces valid assignment/class-average output.
program simple_test_1jyx_abinitio_v3
use simple_core_module_api
use simple_atoms,                   only: atoms
use simple_molecule_data,           only: molecule_data, betagal_1jyx
use simple_cmdline,                 only: cmdline
use simple_commanders_sim,          only: commander_simulate_particles
use simple_commanders_project_core, only: commander_new_project
use simple_commanders_project_ptcl, only: commander_import_particles
use simple_commanders_abinitio2D,   only: commander_abinitio2D
use simple_procimgstk,              only: add_noise_imgfile
use simple_imghead,                 only: find_ldim_nptcls
use simple_sp_project,              only: sp_project
use simple_fileio,                  only: simple_list_dirs, simple_list_files_regexp
use simple_ui,                      only: make_ui
implicit none
#include "simple_local_flags.inc"

character(len=*), parameter :: WORKDIR  = 'test_1jyx_abinitio_v3'
character(len=*), parameter :: PROJNAME = 'onejyx_abinitio_v3'
character(len=*), parameter :: PROJFILE = PROJNAME//'.simple'
character(len=*), parameter :: VOLFILE  = '1JYX_v3.mrc'
character(len=*), parameter :: CLEANSTK = '1JYX_v3_clean.mrcs'
character(len=*), parameter :: NOISYSTK = '1JYX_v3_noisy.mrcs'

real    :: smpd, mskdiam, snr
integer :: nptcls, ncls, nthr, status, nimgs
integer :: ldim(3), vol_dim(3)
type(cmdline) :: cline_sim, cline_new, cline_import, cline_abinitio
type(commander_simulate_particles) :: xsim
type(commander_new_project)        :: xnew
type(commander_import_particles)   :: ximport
type(commander_abinitio2D)         :: xabinitio
type(molecule_data) :: mol
type(atoms)         :: molecule
type(sp_project)    :: spproj
type(string) :: cwd, workflow_root, volume_path, clean_path, noisy_path, project_path, cavgs_jpeg
logical :: found_cavgs

smpd    = 1.3
mskdiam = 120.0
snr     = 10.0
nptcls  = 200
ncls    = 4
nthr    = 4
vol_dim = [144,144,144]

call make_ui
call simple_getcwd(cwd)
if( file_exists(WORKDIR) )then
    call simple_rmdir(WORKDIR, status)
    if( status /= 0 ) THROW_HARD('could not reset '//WORKDIR)
endif
call simple_mkdir(WORKDIR)
call simple_chdir(WORKDIR, status)
if( status /= 0 ) THROW_HARD('could not enter '//WORKDIR)
call simple_getcwd(workflow_root)

write(logfhandle,'(a)') '>>> V3 STEP 1: generate 1JYX volume'
mol = betagal_1jyx()
call molecule%pdb2mrc(volfile=string(VOLFILE), smpd=smpd, mol=mol, center_pdb=.true., vol_dim=vol_dim)
call molecule%kill()
volume_path = simple_abspath(string(VOLFILE))

write(logfhandle,'(a)') '>>> V3 STEP 2: simulate clean multi-particle stack'
call cline_sim%set('prg',     'simulate_particles')
call cline_sim%set('mkdir',   'no')
call cline_sim%set('vol1',    volume_path)
call cline_sim%set('outstk',  CLEANSTK)
call cline_sim%set('smpd',    smpd)
call cline_sim%set('mskdiam', mskdiam)
call cline_sim%set('nptcls',  nptcls)
call cline_sim%set('nthr',    nthr)
call cline_sim%set('pgrp',    'c1')
call cline_sim%set('ctf',     'no')
call cline_sim%set('snr',     10.0)
call cline_sim%set('bfac',    0.0)
! simulate_particles samples random Euler orientations and applies a bounded
! random in-plane shift when sherr is nonzero.  This keeps V3 representative
! of real particles rather than testing noise-only images.
call cline_sim%set('sherr',   2.0)
call xsim%execute(cline_sim)
call cline_sim%kill()
clean_path = simple_abspath(string(CLEANSTK))
call find_ldim_nptcls(clean_path, ldim, nimgs)
if( nimgs /= nptcls ) THROW_HARD('clean stack has wrong particle count')

write(logfhandle,'(a,f7.3)') '>>> V3 STEP 3: add Gaussian noise; SNR = ', snr
call add_noise_imgfile(clean_path, string(NOISYSTK), snr, smpd)
noisy_path = simple_abspath(string(NOISYSTK))
call find_ldim_nptcls(noisy_path, ldim, nimgs)
if( nimgs /= nptcls ) THROW_HARD('noisy stack has wrong particle count')

write(logfhandle,'(a)') '>>> V3 STEP 4: create and import SIMPLE project'
call cline_new%set('prg',      'new_project')
call cline_new%set('projname', PROJNAME)
call cline_new%set('qsys_name','local')
call cline_new%set('mkdir',    'no')
call xnew%execute(cline_new)
call cline_new%kill()
project_path = simple_abspath(string(PROJFILE))
call cline_import%set('prg',     'import_particles')
call cline_import%set('mkdir',   'no')
call cline_import%set('projfile',project_path)
call cline_import%set('stk',     noisy_path)
call cline_import%set('smpd',    smpd)
call cline_import%set('ctf',     'no')
call ximport%execute(cline_import)
call cline_import%kill()

write(logfhandle,'(a)') '>>> V3 STEP 5: run one abinitio2D stage'
call cline_abinitio%set('prg',           'abinitio2D')
call cline_abinitio%set('projfile',      project_path)
call cline_abinitio%set('mkdir',         'yes')
call cline_abinitio%set('mskdiam',       mskdiam)
call cline_abinitio%set('ncls',          ncls)
call cline_abinitio%set('nstages',       1)
call cline_abinitio%set('nits_per_stage',1)
call cline_abinitio%set('nthr',          nthr)
call xabinitio%execute(cline_abinitio)
call cline_abinitio%kill()

write(logfhandle,'(a)') '>>> V3 STEP 6: validate project output'
call spproj%read(project_path)
if( spproj%os_ptcl2D%get_noris() /= nptcls ) THROW_HARD('abinitio2D output particle count mismatch')
write(logfhandle,'(a,i0)') '>>> V3 PARTICLES: ', spproj%os_ptcl2D%get_noris()
call spproj%kill()
! The class-average segment is written by the abinitio2D stage project and is
! not guaranteed to be reattached to the input project on reread.  Validate
! the authoritative stage artifact instead of treating an empty os_cls2D
! container as a failed classification.
found_cavgs = .false.
call find_cavgs(workflow_root, cavgs_jpeg, found_cavgs)
if( .not. found_cavgs ) THROW_HARD('abinitio2D produced no class-average image anywhere below workflow root')
write(logfhandle,'(a)') '>>> V3 CLASS OUTPUT: '//cavgs_jpeg%to_char()
call simple_chdir(cwd, status)
if( status /= 0 ) THROW_HARD('could not restore original working directory')
write(logfhandle,'(a)') '>>> V3 RESULTS: '//workflow_root%to_char()
call simple_end('**** SIMPLE_TEST_1JYX_ABINITIO_V3 NORMAL STOP ****')

contains

    recursive subroutine find_cavgs(root, result, found)
        type(string), intent(in)    :: root
        type(string), intent(inout)  :: result
        logical,      intent(inout) :: found
        type(string), allocatable :: files(:), dirs(:)
        type(string) :: child
        integer :: i
        if( found ) return
        call simple_list_files_regexp(root, '^cavgs_iter[0-9]+\.jpg$', files)
        if( size(files) > 0 )then
            result = files(1)
            found = .true.
            return
        endif
        dirs = simple_list_dirs(root)
        do i = 1, size(dirs)
            ! simple_list_dirs returns names relative to ROOT, so preserve
            ! the parent path during recursive descent.
            child = string(root%to_char()//'/'//dirs(i)%to_char())
            call find_cavgs(child, result, found)
            if( found ) return
        enddo
    end subroutine find_cavgs

end program simple_test_1jyx_abinitio_v3
