module simple_commanders_prob
use simple_commanders_api
use simple_pftc_srch_api
implicit none
#include "simple_local_flags.inc"

type, extends(commander_base) :: commander_prob_tab
  contains
    procedure :: execute      => exec_prob_tab
end type commander_prob_tab

type, extends(commander_base) :: commander_prob_tab_neigh
    contains
        procedure :: execute      => exec_prob_tab_neigh
end type commander_prob_tab_neigh

type, extends(commander_base) :: commander_prob_align
  contains
    procedure :: execute      => exec_prob_align
end type commander_prob_align

type, extends(commander_base) :: commander_prob_align_neigh
    contains
        procedure :: execute      => exec_prob_align_neigh
end type commander_prob_align_neigh

type, extends(commander_base) :: commander_prob_tab2D
  contains
    procedure :: execute      => exec_prob_tab2D
end type commander_prob_tab2D

type, extends(commander_base) :: commander_prob_align2D
  contains
    procedure :: execute      => exec_prob_align2D
end type commander_prob_align2D

contains

    subroutine exec_prob_tab( self, cline )
        use simple_matcher_2Dprep
        use simple_matcher_refvol_utils,    only: read_reprojection_model
        use simple_matcher_ptcl_batch,      only: prep_sigmas_objfun, alloc_ptcl_imgs, build_batch_particles3D, clean_batch_particles3D
        use simple_eul_prob_tab,            only: eul_prob_tab
        class(commander_prob_tab), intent(inout) :: self
        class(cmdline),            intent(inout) :: cline
        integer,     allocatable :: pinds(:)
        type(image), allocatable :: tmp_imgs(:), tmp_imgs_pad(:)
        type(string)             :: fname
        type(builder)            :: build
        type(parameters)         :: params
        type(eul_prob_tab)       :: eulprob_obj_part
        integer :: nptcls, batchsz_max, nbatches, ibatch, batch_start, batch_end, batchsz
        integer, allocatable :: batches(:,:)
        logical :: l_state_only
        call cline%set('mkdir', 'no')
        call build%init_params_and_build_general_tbox(cline,params,do3d=.false.)
        ! The policy here ought to be that nothing is done with regards to sampling other than reproducing
        ! what was generated in the driver (prob_align, below). Sampling is delegated to prob_align (below)
        ! and merely reproduced here
        if( build%spproj_field%has_been_sampled() )then
            call build%spproj_field%sample4update_reprod([params%fromp,params%top], nptcls, pinds)
        else
            THROW_HARD('exec_prob_tab requires prior particle sampling (in exec_prob_align)')
        endif
        if( nptcls < 1 ) THROW_HARD('exec_prob_tab selected no particles')
        batchsz_max = min(nptcls, params%nthr * BATCHTHRSZ)
        nbatches    = ceiling(real(nptcls) / real(batchsz_max))
        batches     = split_nobjs_even(nptcls, nbatches)
        batchsz_max = maxval(batches(:,2) - batches(:,1) + 1)
        ! PREPARE REFERENCES, SIGMAS, POLAR_CORRCALC, PTCLS
        call read_reprojection_model(params, build, batchsz_max)
        call prep_sigmas_objfun(params, build, .false.)
        call alloc_ptcl_imgs( params, build, tmp_imgs, tmp_imgs_pad, batchsz_max )
        call build%pftc%memoize_refs(eulspace=build%eulspace)
        ! Fill the partition table in matcher-sized batches to cap particle PFT memo memory.
        l_state_only = str_has_substr(params%refine, 'prob_state')
        call eulprob_obj_part%new_worker(params,build,pinds)
        fname = string(DIST_FBODY)//int2str_pad(params%part,params%numlen)//'.dat'
        call eulprob_obj_part%begin_write(fname)
        do ibatch = 1, nbatches
            batch_start = batches(ibatch,1)
            batch_end   = batches(ibatch,2)
            batchsz     = batch_end - batch_start + 1
            call build_batch_particles3D(params, build, batchsz, pinds(batch_start:batch_end), tmp_imgs, tmp_imgs_pad)
            if( l_state_only )then
                call eulprob_obj_part%fill_tab_state_only_range(batch_start, batch_end)
            else
                call eulprob_obj_part%fill_tab_range(batch_start, batch_end)
            endif
        end do
        call eulprob_obj_part%write_tab(fname)
        call eulprob_obj_part%kill
        if( allocated(batches) ) deallocate(batches)
        call build%pftc%kill
        call clean_batch_particles3D(build, tmp_imgs, tmp_imgs_pad)
        call build%kill_general_tbox
        call qsys_job_finished(params, string('simple_commanders_refine3D :: exec_prob_tab'))
        call simple_end('**** SIMPLE_PROB_TAB NORMAL STOP ****', print_simple=.false.)
    end subroutine exec_prob_tab

    subroutine exec_prob_tab_neigh( self, cline )
        use simple_matcher_2Dprep
        use simple_matcher_refvol_utils,    only: read_reprojection_model
        use simple_matcher_ptcl_batch,      only: prep_sigmas_objfun, alloc_ptcl_imgs, build_batch_particles3D, clean_batch_particles3D
        use simple_eul_prob_tab_neigh,      only: eul_prob_tab_neigh
        class(commander_prob_tab_neigh), intent(inout) :: self
        class(cmdline),                  intent(inout) :: cline
        integer,     allocatable :: pinds(:)
        type(image), allocatable :: tmp_imgs(:), tmp_imgs_pad(:)
        type(string)             :: fname
        type(builder)            :: build
        type(parameters)         :: params
        type(eul_prob_tab_neigh) :: eulprob_obj_part_neigh
        integer :: nptcls
        call cline%set('mkdir', 'no')
        call build%init_params_and_build_general_tbox(cline,params,do3d=.true.)
        ! Sampling policy mirrors exec_prob_tab: only reproduce already sampled particles.
        if( build%spproj_field%has_been_sampled() )then
            call build%spproj_field%sample4update_reprod([params%fromp,params%top], nptcls, pinds)
        else
            THROW_HARD('exec_prob_tab_neigh requires prior particle sampling (in exec_prob_align)')
        endif
        if( nptcls < 1 ) THROW_HARD('exec_prob_tab_neigh selected no particles')
        ! All neighborhood modes can fill the table in matcher-sized batches; this
        ! caps particle-image/PFT memo memory without changing assignment ownership.
        fname = string(DIST_FBODY)//'_neigh_'//int2str_pad(params%part,params%numlen)//'.dat'
        call run_prob_tab_neigh_batch(fname)
        call fname%kill
        call build%kill_general_tbox
        call qsys_job_finished(params, string('simple_commanders_refine3D :: exec_prob_tab_neigh'))
        call simple_end('**** SIMPLE_PROB_TAB_NEIGH NORMAL STOP ****', print_simple=.false.)

    contains

        subroutine prepare_prob_neigh_workspace(batchsz_here)
            integer, intent(in) :: batchsz_here
            call read_reprojection_model(params, build, batchsz_here)
            call prep_sigmas_objfun(params, build, .false.)
            call alloc_ptcl_imgs(params, build, tmp_imgs, tmp_imgs_pad, batchsz_here)
            call build%pftc%memoize_refs(eulspace=build%eulspace)
        end subroutine prepare_prob_neigh_workspace

        subroutine cleanup_prob_neigh_workspace
            call build%pftc%kill
            call clean_batch_particles3D(build, tmp_imgs, tmp_imgs_pad)
        end subroutine cleanup_prob_neigh_workspace

        subroutine run_prob_tab_neigh_batch(outfname)
            class(string), intent(in)  :: outfname
            integer, allocatable :: batches(:,:)
            integer :: ibatch, batch_start, batch_end, batchsz, batchsz_max, nbatches
            batchsz_max = min(nptcls, max(1, params%nthr * BATCHTHRSZ))
            nbatches    = ceiling(real(nptcls) / real(batchsz_max))
            batches     = split_nobjs_even(nptcls, nbatches)
            batchsz_max = maxval(batches(:,2) - batches(:,1) + 1)
            call prepare_prob_neigh_workspace(batchsz_max)
            call eulprob_obj_part_neigh%new_neigh(params,build,pinds)
            call eulprob_obj_part_neigh%begin_write(outfname)
            do ibatch = 1, nbatches
                batch_start = batches(ibatch,1)
                batch_end   = batches(ibatch,2)
                batchsz     = batch_end - batch_start + 1
                call build_batch_particles3D(params, build, batchsz, pinds(batch_start:batch_end), tmp_imgs, tmp_imgs_pad)
                call eulprob_obj_part_neigh%fill_tab_range(batch_start, batch_end)
            enddo
            call eulprob_obj_part_neigh%write_tab(outfname)
            call eulprob_obj_part_neigh%kill
            if( allocated(batches) ) deallocate(batches)
            call cleanup_prob_neigh_workspace
        end subroutine run_prob_tab_neigh_batch

    end subroutine exec_prob_tab_neigh


    subroutine exec_prob_align( self, cline )
        use simple_eul_prob_tab,            only: eul_prob_tab
        use simple_matcher_smpl_and_lplims, only: sample_ptcls4fillin, sample_ptcls4update3D
        use simple_builder,                 only: builder
        class(commander_prob_align), intent(inout) :: self
        class(cmdline),              intent(inout) :: cline
        integer,     allocatable :: pinds(:)
        type(string)             :: fname
        type(builder)            :: build
        type(parameters)         :: params
        type(commander_prob_tab) :: xprob_tab
        type(eul_prob_tab)       :: eulprob_obj_glob
        type(cmdline)            :: cline_prob_tab
        type(qsys_env)           :: qenv
        type(chash)              :: job_descr
        integer :: nptcls, ipart
        logical :: l_state_only
        call cline%set('mkdir',  'no')
        call cline%set('stream', 'no')
        call build%init_params_and_build_general_tbox(cline, params, do3d=.false.)
        if( params%startit == 1 ) call build%spproj_field%clean_entry('updatecnt', 'sampled')
        ! sampled incremented
        if( params%l_fillin .and. mod(params%startit,5) == 0 )then
            call sample_ptcls4fillin(params, build, [1,params%nptcls], .true., nptcls, pinds)
        else
            call sample_ptcls4update3D(params, build, [1,params%nptcls], .true., nptcls, pinds)
        endif
        ! communicate to project file
        call build%spproj%write_segment_inside(params%oritype)
        call cleanup_prob_align_outputs(params, .false.)
        ! generating all corrs on all parts
        cline_prob_tab = cline
        call cline_prob_tab%set('prg', 'prob_tab' ) ! required for distributed call
        ! execution
        if( .not.cline_prob_tab%defined('nparts') )then
            call xprob_tab%execute(cline_prob_tab)
        else
            ! setup the environment for distributed execution
            call qenv%new(params, params%nparts, nptcls=params%nptcls)
            call cline_prob_tab%gen_job_descr(job_descr)
            ! schedule
            call qenv%gen_scripts_and_schedule_jobs(job_descr, array=L_USE_SLURM_ARR, extra_params=params)
        endif
        ! Build the global table only after worker tables are complete.  Keeping it
        ! live while workers build dense partition tables roughly doubles peak RSS.
        l_state_only = str_has_substr(params%refine, 'prob_state')
        if( l_state_only )then
            call eulprob_obj_glob%new_state(params,build,pinds)
        else
            call eulprob_obj_glob%new(params,build,pinds)
        endif
        ! reading corrs from all parts
        if( l_state_only )then
            do ipart = 1, params%nparts
                fname = string(DIST_FBODY)//int2str_pad(ipart,params%numlen)//'.dat'
                call eulprob_obj_glob%read_state_tab(fname)
            enddo
            call eulprob_obj_glob%state_assign
        else
            do ipart = 1, params%nparts
                fname = string(DIST_FBODY)//int2str_pad(ipart,params%numlen)//'.dat'
                call eulprob_obj_glob%read_tab_to_glob(fname)
            enddo
            call eulprob_obj_glob%ref_assign
        endif
        ! write the iptcl->(iref,istate) assignment
        fname = string(ASSIGNMENT_FBODY)//'.dat'
        call eulprob_obj_glob%write_assignment(fname)
        call eulprob_obj_glob%kill
        ! cleanup
        call cline_prob_tab%kill
        call qenv%kill
        call job_descr%kill
        call build%kill_general_tbox
        call qsys_job_finished(params, string('simple_commanders_refine3D :: exec_prob_align'))
        call qsys_cleanup(params)
        call simple_end('**** SIMPLE_PROB_ALIGN NORMAL STOP ****', print_simple=.false.)
    end subroutine exec_prob_align

    subroutine exec_prob_align_neigh( self, cline )
        use simple_eul_prob_tab_neigh,      only: eul_prob_tab_neigh
        use simple_matcher_smpl_and_lplims, only: sample_ptcls4fillin, sample_ptcls4update3D
        use simple_builder,                 only: builder
        class(commander_prob_align_neigh), intent(inout) :: self
        class(cmdline),                    intent(inout) :: cline
        integer,           allocatable :: pinds(:)
        type(string)                   :: fname
        type(builder)                  :: build
        type(parameters)               :: params
        type(commander_prob_tab_neigh) :: xprob_tab_neigh
        type(eul_prob_tab_neigh)       :: eulprob_obj_glob_neigh
        type(cmdline)                  :: cline_prob_tab
        type(qsys_env)                 :: qenv
        type(chash)                    :: job_descr
        integer :: nptcls
        call cline%set('mkdir',  'no')
        call cline%set('stream', 'no')
        call build%init_params_and_build_general_tbox(cline, params, do3d=.true.)
        if( params%startit == 1 ) call build%spproj_field%clean_entry('updatecnt', 'sampled')
        if( params%l_fillin .and. mod(params%startit,5) == 0 )then
            call sample_ptcls4fillin(params, build, [1,params%nptcls], .true., nptcls, pinds)
        else
            call sample_ptcls4update3D(params, build, [1,params%nptcls], .true., nptcls, pinds)
        endif
        call build%spproj%write_segment_inside(params%oritype)
        call cleanup_prob_align_outputs(params, .true.)
        cline_prob_tab = cline
        call cline_prob_tab%set('prg', 'prob_tab_neigh')
        if( .not. cline_prob_tab%defined('nparts') )then
            call xprob_tab_neigh%execute(cline_prob_tab)
        else
            call qenv%new(params, params%nparts, nptcls=params%nptcls)
            call cline_prob_tab%gen_job_descr(job_descr)
            call qenv%gen_scripts_and_schedule_jobs(job_descr, array=L_USE_SLURM_ARR, extra_params=params)
        endif
        ! Construct global storage only after worker scoring has released its table.
        call eulprob_obj_glob_neigh%new_neigh_global(params,build,pinds)
        call eulprob_obj_glob_neigh%read_tabs_to_glob(string(DIST_FBODY)//'_neigh_', params%nparts, params%numlen)
        call eulprob_obj_glob_neigh%ref_assign
        ! write the iptcl->(iref,istate) assignment
        fname = string(ASSIGNMENT_FBODY)//'.dat'
        call eulprob_obj_glob_neigh%write_assignment(fname)
        call eulprob_obj_glob_neigh%kill
        ! cleanup
        call cline_prob_tab%kill
        call qenv%kill
        call job_descr%kill
        call build%kill_general_tbox
        call qsys_job_finished(params, string('simple_commanders_refine3D :: exec_prob_align_neigh'))
        call qsys_cleanup(params)
        call simple_end('**** SIMPLE_PROB_ALIGN_NEIGH NORMAL STOP ****', print_simple=.false.)
    end subroutine exec_prob_align_neigh

    subroutine exec_prob_tab2D( self, cline )
        use simple_matcher_smpl_and_lplims, only: set_bp_range2D
        use simple_strategy2D_matcher,  only: set_b_p_ptrs2D, &
                                              ptcl_imgs, ptcl_match_imgs, ptcl_match_imgs_pad
        use simple_matcher_pftc_prep,      only: prep_pftc4align2D
        use simple_matcher_ptcl_batch,  only: alloc_ptcl_imgs, build_batch_particles2D, clean_batch_particles2D
        use simple_imgarr_utils,        only: alloc_imgarr
        use simple_classaverager,       only: cavger_new, cavger_read_all, cavger_kill
        use simple_eul_prob_tab2D,      only: eul_prob_tab2D
        class(commander_prob_tab2D), intent(inout) :: self
        class(cmdline),              intent(inout) :: cline
        integer,     allocatable :: pinds(:)
        type(string)             :: fname
        type(builder)            :: build
        type(parameters)         :: params
        type(eul_prob_tab2D)     :: eulprob_obj_part
        real    :: frac_srch_space
        integer :: nptcls, batchsz_max, nbatches, ibatch, batch_start, batch_end, batchsz
        integer, allocatable :: batches(:,:)
        call cline%set('mkdir', 'no')
        call build%init_params_and_build_general_tbox(cline, params, do3d=.false.)
        if( build%spproj_field%get_nevenodd() == 0 )then
            call build%spproj_field%partition_eo
            call build%spproj%write_segment_inside(params%oritype, params%projfile)
        endif
        frac_srch_space  = build%spproj_field%get_avg('frac')
        call set_bp_range2D(params, build, cline, params%which_iter, frac_srch_space)
        ! reproduce particle sampling from exec_prob_align2D
        if( build%spproj_field%has_been_sampled() )then
            call build%spproj_field%sample4update_reprod([params%fromp,params%top], nptcls, pinds)
        else
            THROW_HARD('exec_prob_tab2D requires prior particle sampling (in exec_prob_align2D)')
        endif
        batchsz_max = min(nptcls, params%nthr * BATCHTHRSZ)
        nbatches    = ceiling(real(nptcls) / real(batchsz_max))
        batches     = split_nobjs_even(nptcls, nbatches)
        batchsz_max = maxval(batches(:,2) - batches(:,1) + 1)
        call set_b_p_ptrs2D(params, build)
        call alloc_ptcl_imgs(params, build, ptcl_match_imgs, ptcl_match_imgs_pad, batchsz_max)
        call alloc_imgarr(batchsz_max, [params%box, params%box, 1], params%smpd, ptcl_imgs)
        ! mirror cluster2D_exec reference setup
        call cavger_new(params, build)
        if( .not. cline%defined('refs') ) THROW_HARD('exec_prob_tab2D requires refs on the command line')
        call cavger_read_all
        call prep_pftc4align2D(params, build, ptcl_match_imgs_pad, batchsz_max, params%which_iter, .false.)
        ! Fill the partition table in matcher-sized batches to cap polar FT memo memory.
        call eulprob_obj_part%new_worker(params,build,pinds)
        do ibatch = 1, nbatches
            batch_start = batches(ibatch,1)
            batch_end   = batches(ibatch,2)
            batchsz     = batch_end - batch_start + 1
            call build_batch_particles2D(params, build, batchsz, pinds(batch_start:batch_end),&
                &ptcl_imgs(1:batchsz), ptcl_match_imgs, ptcl_match_imgs_pad)
            call eulprob_obj_part%fill_tab_range(batch_start, batch_end)
        end do
        ! write the 2D probability table
        fname = string(DIST_FBODY)//int2str_pad(params%part,params%numlen)//'.dat'
        call eulprob_obj_part%write_tab(fname)
        call eulprob_obj_part%kill
        if( allocated(batches) ) deallocate(batches)
        call clean_batch_particles2D(build, ptcl_imgs, ptcl_match_imgs, ptcl_match_imgs_pad)
        call cavger_kill
        call build%pftc%kill
        call build%kill_general_tbox
        call qsys_job_finished(params, string('simple_commanders_prob :: exec_prob_tab2D'))
        call simple_end('**** SIMPLE_PROB_TAB2D NORMAL STOP ****', print_simple=.false.)
    end subroutine exec_prob_tab2D

    subroutine exec_prob_align2D( self, cline )
        use simple_eul_prob_tab2D,          only: eul_prob_tab2D, PRIOR2D_STAGE5_FNAME
        use simple_eul_prob_tab_utils,      only: materialize_seed_shift
        use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table, joint2D_balance_diag,&
            &JOINT2D_CANDIDATES_FNAME
        use simple_strategy2D_joint_sgd_refs, only: joint2D_ref_refresh_policy
        use simple_strategy2D_matcher,      only: set_b_p_ptrs2D
        use simple_matcher_smpl_and_lplims, only: sample_ptcls4update2D
        use simple_builder,                 only: builder
        class(commander_prob_align2D), intent(inout) :: self
        class(cmdline),                intent(inout) :: cline
        integer,       allocatable :: pinds(:)
        type(string)               :: fname
        type(builder)              :: build
        type(parameters)           :: params
        type(commander_prob_tab2D) :: xprob_tab2D
        type(eul_prob_tab2D)       :: eulprob_obj_glob
        type(joint2D_candidate_table) :: joint_candidates, joint_candidates_part
        type(joint2D_balance_diag)    :: balance_diag
        type(joint2D_ref_refresh_policy) :: ref_policy
        type(cmdline)              :: cline_prob_tab
        type(qsys_env)             :: qenv
        type(chash)                :: job_descr
        real, allocatable :: base_shifts(:,:)
        integer, allocatable :: part_pinds(:)
        integer :: nptcls, nptcls_part, ipart, iptcl
        call cline%set('mkdir',  'no')
        call cline%set('stream', 'no')
        call build%init_params_and_build_general_tbox(cline, params, do3d=.false.)
        call set_b_p_ptrs2D(params, build)
        if( build%spproj_field%get_nevenodd() == 0 )then
            call build%spproj_field%partition_eo
            call build%spproj%write_segment_inside(params%oritype, params%projfile)
        endif
        if( params%startit == 1 .and. params%which_iter == params%startit )then
            call build%spproj_field%clean_entry('updatecnt', 'sampled')
        endif
        ! Mirror the 3D workflow: sampled-update is active from the first stage onward.
        ! In probabilistic mode the sampled subset is reused within the current iteration
        ! by prob_tab2D/cluster2D_exec, but it is redrawn on later iterations.
        if( params%l_sgd .and. trim(params%sgd_mode) == 'joint' )then
            call sample_ptcls4update2D(params, build, [params%fromp,params%top], .true., nptcls, pinds,&
                &update_frac_override=params%sgd_batch_frac, force_resample=.true.,&
                &max_samples_override=params%nsample)
            write(logfhandle,'(A,F6.3,A,I0,A,I0)') '>>> JOINT2D SGD MINI-BATCH: fraction=',&
                &params%sgd_batch_frac, ' cap=', params%nsample, ' sampled=', nptcls
        else
            call sample_ptcls4update2D(params, build, [params%fromp,params%top], params%l_update_frac, nptcls, pinds)
        endif
        write(logfhandle,'(A,I0,A,I0,A,I0)') '>>> PROB_ALIGN2D: sampled ', nptcls, ' particles over ', params%nparts, ' part(s)'
        call flush(logfhandle)
        ! write sampling to project
        call build%spproj%write_segment_inside(params%oritype)
        call del_file(JOINT2D_CANDIDATES_FNAME)
        ! build the global prob table (nclasses x nptcls)
        call eulprob_obj_glob%new(params, build, pinds)
        ! generate partition-wise dist tables
        cline_prob_tab = cline
        call cline_prob_tab%set('prg', 'prob_tab2D')
        call cline_prob_tab%set('sgd', 'no')
        if( params%l_sgd .and. trim(params%sgd_mode) == 'joint' )then
            call cline_prob_tab%set('sgd_likelihood_units', 'gaussian_nll')
        else
            call cline_prob_tab%set('sgd_likelihood_units', 'normalized')
        endif
        if( params%l_sgd .and. trim(params%sgd_mode) == 'joint' .and. params%l_sgd_diag )then
            call cline_prob_tab%set('sgd_diag', 'yes')
        else
            call cline_prob_tab%set('sgd_diag', 'no')
        endif
        if( .not. cline_prob_tab%defined('nparts') )then
            call xprob_tab2D%execute(cline_prob_tab)
        else
            call qenv%new(params, params%nparts, nptcls=params%nptcls)
            call cline_prob_tab%gen_job_descr(job_descr)
            call qenv%gen_scripts_and_schedule_jobs(job_descr, array=L_USE_SLURM_ARR, extra_params=params)
        endif
        write(logfhandle,'(A)') '>>> PROB_ALIGN2D: prob_tab2D workers completed; merging partition tables'
        call flush(logfhandle)
        ! merge all partition tables into global
        do ipart = 1, params%nparts
            fname = string(DIST_FBODY)//int2str_pad(ipart,params%numlen)//'.dat'
            call eulprob_obj_glob%read_tab_to_glob(fname)
        end do
        ! global probabilistic class assignment
        if( params%l_sgd .and. trim(params%sgd_mode) == 'joint' )then
            call ref_policy%new(params%refs%to_char(), params%which_iter)
            call ref_policy%require_input_refs('prob_align2D')
            call ref_policy%write_diag('prob_align2D')
            write(logfhandle,'(A)') '>>> PROB_ALIGN2D: running joint-SGD top-K hard assignment'
        else
            write(logfhandle,'(A)') '>>> PROB_ALIGN2D: running global probabilistic assignment'
        endif
        call flush(logfhandle)
        if( params%l_sgd .and. trim(params%sgd_mode) == 'joint' )then
            call joint_candidates%build_from_loc_tab(eulprob_obj_glob%loc_tab, params%sgd_topk, pinds=pinds)
            allocate(base_shifts(2,eulprob_obj_glob%nptcls), source=0.)
            do iptcl = 1, eulprob_obj_glob%nptcls
                if( pinds(iptcl) > 0 ) base_shifts(:,iptcl) = build%spproj_field%get_2Dshift(pinds(iptcl))
            end do
            call joint_candidates%set_base_shifts(base_shifts)
            call joint_candidates%optimize_logits(params%sgd_inner_its, params%sgd_eta_latent)
            call joint_candidates%evaluate_reliability(params%sgd_cavg_min_cands, params%sgd_cavg_max_entropy)
            call joint_candidates%apply_balance_prior(params%ncls, params%sgd_balance_weight, balance_diag)
            call joint_candidates%evaluate_reliability(params%sgd_cavg_min_cands, params%sgd_cavg_max_entropy)
            if( count(joint_candidates%accepted) == 0 )then
                write(logfhandle,'(A)') '>>> JOINT2D SGD: provisional candidate reliability accepted zero soft particles'
            endif
            call joint_candidates%write_balance_diag('prob_align2D', balance_diag)
            call joint_candidates%write_diag('prob_align2D provisional reliability', iteration=params%which_iter)
            call joint_candidates%write_table(JOINT2D_CANDIDATES_FNAME)
            if( params%nparts > 1 .and. allocated(qenv%parts) )then
                do ipart = 1, params%nparts
                    if( allocated(part_pinds) ) deallocate(part_pinds)
                    call build%spproj_field%sample4update_reprod(qenv%parts(ipart,:), nptcls_part, part_pinds)
                    if( nptcls_part < 1 ) cycle
                    call joint_candidates%extract_by_pinds(part_pinds, joint_candidates_part)
                    call joint_candidates_part%write_part_table(ipart, params%numlen)
                    call joint_candidates_part%write_distributed_diag('prob_align2D write-part', ipart, params%nparts)
                    call joint_candidates_part%kill
                end do
                if( allocated(part_pinds) ) deallocate(part_pinds)
            endif
            call joint_candidates%write_hard_assignments(eulprob_obj_glob%assgn_map)
            do iptcl = 1, eulprob_obj_glob%nptcls
                call materialize_seed_shift(eulprob_obj_glob%assgn_map(iptcl), eulprob_obj_glob%seed_shifts(:,iptcl),&
                    &eulprob_obj_glob%seed_has_sh(iptcl), params%l_doshift, eulprob_obj_glob%seed_nrots)
                if( eulprob_obj_glob%l_sparse_snhc .and. allocated(eulprob_obj_glob%eval_touched_counts) )then
                    eulprob_obj_glob%assgn_map(iptcl)%frac = 100. * real(eulprob_obj_glob%eval_touched_counts(iptcl))&
                        &/ real(eulprob_obj_glob%nclasses)
                    eulprob_obj_glob%assgn_map(iptcl)%npeaks = eulprob_obj_glob%eval_touched_counts(iptcl)
                else
                    eulprob_obj_glob%assgn_map(iptcl)%frac = 100.
                endif
            end do
            if( allocated(base_shifts) ) deallocate(base_shifts)
            call joint_candidates_part%kill
            call joint_candidates%kill
        else
            call eulprob_obj_glob%ref_assign
        endif
        ! write assignment to file
        fname = string(ASSIGNMENT_FBODY)//'.dat'
        write(logfhandle,'(A,A)') '>>> PROB_ALIGN2D: writing assignment ', fname%to_char()
        call flush(logfhandle)
        call eulprob_obj_glob%write_assignment(fname)
        write(logfhandle,'(A)') '>>> PROB_ALIGN2D: assignment written'
        call flush(logfhandle)
        ! write per-particle prior ranking only when the controller has flagged this as the
        ! prior-production stage (stage PROB_PRIOR_STAGE-1, i.e. stage 5 by default)
        if( trim(params%write_prior) == 'yes' )then
            fname = string(PRIOR2D_STAGE5_FNAME)
            call eulprob_obj_glob%write_prior_topk(fname)
            write(logfhandle,'(A,A)') '>>> PROB_ALIGN2D: prior ranking written ', fname%to_char()
            call flush(logfhandle)
        endif
        ! cleanup
        call eulprob_obj_glob%kill
        call cline_prob_tab%kill
        call qenv%kill
        call job_descr%kill
        call build%kill_general_tbox
        call qsys_job_finished(params, string('simple_commanders_prob :: exec_prob_align2D'))
        call qsys_cleanup(params)
        call simple_end('**** SIMPLE_PROB_ALIGN2D NORMAL STOP ****', print_simple=.false.)
    end subroutine exec_prob_align2D

    subroutine cleanup_prob_align_outputs( params, neigh )
        class(parameters), intent(in) :: params
        logical,           intent(in) :: neigh
        type(string) :: fname
        integer :: ipart
        if( neigh )then
            do ipart = 1, params%nparts
                fname = string(DIST_FBODY)//'_neigh_'//int2str_pad(ipart,params%numlen)//'.dat'
                call del_file(fname)
            end do
        else
            call del_files(DIST_FBODY, params%nparts, ext='.dat', numlen=params%numlen)
        endif
        call del_file(string(ASSIGNMENT_FBODY)//'.dat')
        call fname%kill
    end subroutine cleanup_prob_align_outputs

end module simple_commanders_prob
