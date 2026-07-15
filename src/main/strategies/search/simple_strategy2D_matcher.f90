!@descr: high-level search routines for the cluster2D and abinitio2D applications
module simple_strategy2D_matcher
use simple_pftc_srch_api
use simple_classaverager
use simple_binoris_io,               only: binwrite_oritab
use simple_progress,                 only: progressfile_update
use simple_strategy2D_alloc,         only: clean_strategy2D, prep_strategy2D_batch, prep_strategy2D_glob, &
                                           s2D, set_strategy2D_stoch_bound, is_fresh_2D_start
use simple_builder,                  only: builder
use simple_qsys_funs,                only: qsys_job_finished
use simple_syslib,                   only: get_peak_rss_bytes
use simple_strategy2D,               only: strategy2D, strategy2D_per_ptcl
use simple_matcher_pftc_prep,        only: prep_pftc4align2D
use simple_matcher_smpl_and_lplims,  only: set_bp_range2d, sample_ptcls4update2D, cluster2D_requires_full_assignment, &
                                           all_active_ptcls_2D_assigned
use simple_matcher_ptcl_batch,       only: alloc_ptcl_imgs, build_batch_particles2D, clean_batch_particles2D
use simple_imgarr_utils,             only: alloc_imgarr
use simple_strategy2D_greedy,        only: strategy2D_greedy
use simple_strategy2D_greedy_smpl,   only: strategy2D_greedy_smpl
use simple_strategy2D_inpl,          only: strategy2D_inpl
use simple_strategy2D_inpl_smpl,     only: strategy2D_inpl_smpl
use simple_strategy2D_snhc,          only: strategy2D_snhc
use simple_strategy2D_snhc_smpl,     only: strategy2D_snhc_smpl
use simple_strategy2D_snhc_smpl_many,only: strategy2D_snhc_smpl_many
use simple_strategy2D_prob,          only: strategy2D_prob
use simple_strategy2D_srch,          only: strategy2D_spec
use simple_strategy2D_tseries,       only: strategy2D_tseries
use simple_strategy2D_joint_sgd,     only: cluster2D_joint_sgd_exec
use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table, joint2D_balance_diag,&
                                                  JOINT2D_CANDIDATES_FNAME, joint2D_candidate_part_fname
use simple_strategy2D_joint_sgd_refs, only: joint2D_ref_refresh_policy
use simple_eul_prob_tab2D,           only: eul_prob_tab2D
use simple_eul_prob_tab_utils,       only: eulprob_corr_switch, eulprob_dist_switch
use simple_pftc_shsrch_grad,         only: pftc_shsrch_grad
implicit none

public :: cluster2D_exec
public :: set_b_p_ptrs2D
public :: ptcl_imgs, ptcl_match_imgs, ptcl_match_imgs_pad
private
#include "simple_local_flags.inc"

type(image),   allocatable :: ptcl_imgs(:), ptcl_match_imgs(:), ptcl_match_imgs_pad(:)
class(builder),    pointer :: b_ptr => null()
class(parameters), pointer :: p_ptr => null()
real(timer_int_kind)       :: rt_startup, rt_alloc_ptcl_imgs2D, rt_prep_pftc_refs2D
real(timer_int_kind)       :: rt_build_batch_particles2D, rt_align, rt_cavg, rt_tot
real(timer_int_kind)       :: rt_cavg_interp_splat
integer(timer_int_kind)    :: t, t_startup, t_alloc_ptcl_imgs2D, t_prep_pftc_refs2D
integer(timer_int_kind)    :: t_build_batch_particles2D, t_align, t_cavg, t_tot
type(string)               :: benchfname

type :: cluster2D_ctrl
    character(len=:), allocatable :: refine_flag
    logical :: l_partial_sums
    logical :: l_sample_updates
    logical :: l_frac_restore
    logical :: l_ctf
    logical :: l_snhc
    logical :: l_stream
    logical :: l_greedy
    logical :: l_np_cls_defined
    logical :: l_prob_align
    logical :: l_joint_topk
    logical :: l_restore_cavgs
    logical :: l_require_full_assignment
    logical :: do_bench
  contains
    procedure :: display
end type cluster2D_ctrl

contains

    subroutine set_b_p_ptrs2D( params, build )
        class(parameters), target, intent(in) :: params
        class(builder),    target, intent(in) :: build
        p_ptr => params
        b_ptr => build
    end subroutine set_b_p_ptrs2D

    !>  \brief  is the prime2D algorithm
    subroutine cluster2D_exec( params, build, cline, which_iter, converged )
        use simple_convergence, only: convergence
        use simple_decay_funs,  only: extremal_decay2D
        class(parameters), target, intent(in)    :: params
        class(builder),    target, intent(in)    :: build
        class(cmdline),            intent(inout) :: cline
        integer,                   intent(in)    :: which_iter
        logical,                   intent(inout) :: converged
        type(strategy2D_per_ptcl), allocatable   :: strategy2Dsrch(:)
        real,                      allocatable   :: states(:), incr_shifts(:,:)
        integer,                   allocatable   :: pinds(:), batches(:,:)
        type(eul_prob_tab2D),      target        :: eulprob_obj_part
        type(joint2D_candidate_table)            :: joint_topk_candidates
        type(joint2D_ref_refresh_policy)         :: joint_ref_policy
        type(ptcl_ref),             allocatable  :: joint_topk_refs(:,:)
        real,                       allocatable  :: joint_topk_weights(:,:)
        integer,                    allocatable  :: joint_topk_ncands(:)
        type(cluster2D_ctrl)                     :: ctrl
        type(ori)             :: orientation
        type(convergence)     :: conv
        type(strategy2D_spec) :: strategy2Dspec
        real    :: frac_srch_space, neigh_frac
        integer :: iptcl, fnr, iptcl_map, iptcl_batch, ibatch, nptcls2update
        integer :: batchsz_max, batchsz, nbatches, batch_start, batch_end
        p_ptr => params
        b_ptr => build
        if( p_ptr%l_sgd .and. (trim(p_ptr%sgd_mode) == 'joint') )then
            if( p_ptr%l_prob_align_mode )then
                write(logfhandle,'(A)') '>>> JOINT 2D SGD: consuming top-K assignment from prob_align2D'
            else
                call cluster2D_joint_sgd_exec(params, build, cline, which_iter, converged)
                return
            endif
        endif
        call init_ctrl()
        if( ctrl%do_bench )then
            t_startup = tic()
            t_tot     = t_startup
        endif
        frac_srch_space = b_ptr%spproj_field%get_avg('frac')
        call sample_particles_for_update()
        call compute_neigh_frac( neigh_frac )
        if( file_exists(p_ptr%frcs) ) call b_ptr%clsfrcs%read(p_ptr%frcs)
        call prepare_batches()
        call ensure_even_odd_partition()
        call prepare_class_averages_and_restoration()
        call set_bp_range2D(p_ptr, b_ptr, cline, which_iter, frac_srch_space)
        if( ctrl%do_bench )then
            rt_startup                 = toc(t_startup)
            rt_build_batch_particles2D = 0.0
            t_alloc_ptcl_imgs2D        = tic()
        endif
        call alloc_ptcl_imgs(p_ptr, b_ptr, ptcl_match_imgs, ptcl_match_imgs_pad, batchsz_max)
        call alloc_imgarr(batchsz_max, [p_ptr%box, p_ptr%box, 1], p_ptr%smpd, ptcl_imgs)
        if( ctrl%do_bench )then
            rt_alloc_ptcl_imgs2D = toc(t_alloc_ptcl_imgs2D)
            t_prep_pftc_refs2D   = tic()
        endif
        call set_strategy2D_stoch_bound(params%ncls, neigh_frac)
        call prepare_alignment_references(batchsz_max)
        if( ctrl%do_bench ) rt_prep_pftc_refs2D = toc(t_prep_pftc_refs2D)
        call prep_strategy2D_glob(p_ptr, b_ptr%spproj, b_ptr%pftc%get_nrots(), neigh_frac)
        if( L_VERBOSE_GLOB ) write(logfhandle,'(A)') '>>> STRATEGY2D OBJECTS ALLOCATED'
        if( ctrl%l_prob_align )then
            call eulprob_obj_part%new_assignment(p_ptr,b_ptr,pinds)
            call eulprob_obj_part%read_assignment(string(ASSIGNMENT_FBODY)//'.dat')
            if( ctrl%l_joint_topk ) call read_joint_topk_candidates()
        endif
        allocate(strategy2Dsrch(batchsz_max))
        rt_align = 0.0
        rt_cavg  = 0.0
        rt_cavg_interp_splat = 0.0
        do ibatch = 1, nbatches
            batch_start = batches(ibatch,1)
            batch_end   = batches(ibatch,2)
            batchsz     = batch_end - batch_start + 1
            call build_batch_particles_local()
            call prep_strategy2D_batch( p_ptr, b_ptr%spproj, which_iter, batchsz, pinds(batch_start:batch_end) )
            if( ctrl%do_bench ) t_align = tic()
            !$omp parallel do private(iptcl,iptcl_batch,iptcl_map,orientation,strategy2Dspec)&
            !$omp default(shared) schedule(static) proc_bind(close)
            do iptcl_batch = 1, batchsz
                iptcl_map  = batch_start + iptcl_batch - 1
                iptcl      = pinds(iptcl_map)
                call allocate_strategy_for_particle(iptcl, iptcl_batch)
                strategy2Dspec%iptcl       = iptcl
                strategy2Dspec%iptcl_batch = iptcl_batch
                strategy2Dspec%iptcl_map   = iptcl_map
                strategy2Dspec%stoch_bound = neigh_frac
                if( ctrl%l_prob_align ) strategy2Dspec%eulprob_obj_part2D => eulprob_obj_part
                call strategy2Dsrch(iptcl_batch)%ptr%new(p_ptr, strategy2Dspec, b_ptr)
                call strategy2Dsrch(iptcl_batch)%ptr%srch(b_ptr%spproj_field)
                incr_shifts(:,iptcl_batch) = strategy2Dsrch(iptcl_batch)%ptr%s%best_shvec
                if ( p_ptr%cc_objfun == OBJFUN_EUCLID ) then
                    call b_ptr%spproj_field%get_ori(iptcl, orientation)
                    call orientation%set_shift(incr_shifts(:,iptcl_batch))
                    call b_ptr%esig%calc_sigma2(b_ptr%pftc, iptcl, orientation, 'class')
                end if
                call strategy2Dsrch(iptcl_batch)%ptr%kill
            enddo
            !$omp end parallel do
            if( ctrl%do_bench )then
                rt_align = rt_align + toc(t_align)
                t_cavg   = tic()
            endif
            if( ctrl%l_joint_topk )then
                call refine_joint_topk_for_batch()
            else
                call accumulate_class_averages_for_batch()
            endif
            if( ctrl%do_bench ) rt_cavg = rt_cavg + toc(t_cavg)
        enddo
        if( ctrl%l_joint_topk )then
            call finalize_joint_topk_reliability()
            ! Final soft reliability and reduced uncertain support are global to the
            ! outer SGD batch. Stream the particle images a second time so no
            ! class-average sums are committed before those weights are finalized.
            do ibatch = 1, nbatches
                batch_start = batches(ibatch,1)
                batch_end   = batches(ibatch,2)
                batchsz     = batch_end - batch_start + 1
                call build_batch_particles_local()
                if( ctrl%do_bench ) t_cavg = tic()
                call accumulate_class_averages_for_batch()
                if( ctrl%do_bench ) rt_cavg = rt_cavg + toc(t_cavg)
            enddo
            call write_refined_joint_topk_candidates()
        endif
        call cleanup_search_state(strategy2Dsrch, pinds, batches, eulprob_obj_part, batchsz_max, orientation)
        if( p_ptr%cc_objfun == OBJFUN_EUCLID ) call b_ptr%esig%write_sigma2
        call write_orientations()
        call finalize_restoration_and_convergence(states, cline, conv, which_iter, converged)
        call b_ptr%esig%kill
        call b_ptr%pftc%kill
        call qsys_job_finished(p_ptr, string('simple_strategy2D_matcher :: cluster2D_exec'))
        call maybe_write_bench(which_iter)

contains

        subroutine init_ctrl()
            ctrl%refine_flag       = trim(p_ptr%refine)
            ctrl%l_snhc            = str_has_substr(ctrl%refine_flag, 'snhc')
            ctrl%l_greedy          = str_has_substr(ctrl%refine_flag, 'greedy')
            ctrl%l_stream          = (trim(p_ptr%stream2d) == 'yes')
            ctrl%l_sample_updates  = p_ptr%l_update_frac
            ctrl%l_frac_restore    = ctrl%l_sample_updates
            ctrl%l_partial_sums    = ctrl%l_frac_restore .or. &
                (p_ptr%l_sgd .and. (trim(p_ptr%sgd_mode) == 'cavg_only'))
            ctrl%l_prob_align      = p_ptr%l_prob_align_mode
            ctrl%l_joint_topk      = p_ptr%l_sgd .and. (trim(p_ptr%sgd_mode) == 'joint') .and. ctrl%l_prob_align
            ctrl%l_restore_cavgs   = (trim(p_ptr%restore_cavgs) == 'yes')
            ctrl%l_require_full_assignment = cluster2D_requires_full_assignment(p_ptr)
            ctrl%l_np_cls_defined  = cline%defined('nptcls_per_cls')
            ctrl%do_bench          = L_BENCH_GLOB
            if( p_ptr%startit == 1 )then
                ctrl%l_frac_restore = .false.
                ctrl%l_partial_sums = .false.
            endif
            if( p_ptr%extr_iter == 1 )then
                ctrl%l_greedy       = .true.
                ctrl%l_snhc         = .false.
            else if( p_ptr%extr_iter > p_ptr%extr_lim )then
                if( trim(ctrl%refine_flag) == 'snhc_smpl' ) ctrl%refine_flag = 'snhc'
            endif
            if( ctrl%l_stream )then
                ctrl%l_sample_updates = .false.
                ctrl%l_frac_restore   = .false.
                if( (which_iter > 1) .and. (p_ptr%update_frac < 0.99) )then
                    p_ptr%l_update_frac   = .true.
                    ctrl%l_sample_updates = .true.
                    ctrl%l_frac_restore   = .true.
                    ctrl%l_partial_sums   = .true.
                else
                    p_ptr%update_frac     = 1.0
                    p_ptr%l_update_frac   = .false.
                    ctrl%l_sample_updates = .false.
                    ctrl%l_frac_restore   = .false.
                    ctrl%l_partial_sums   = p_ptr%l_sgd .and. (trim(p_ptr%sgd_mode) == 'cavg_only')
                endif
                if( trim(ctrl%refine_flag) == 'snhc' ) ctrl%refine_flag = 'snhc_smpl'
            endif
            if( ctrl%l_joint_topk )then
                ! The outer sample was already drawn by prob_align2D. Mark the effective
                ! fraction for convergence, but do not enable legacy fractional carry-over;
                ! joint SGD captures and updates the previous references explicitly.
                p_ptr%l_update_frac     = .true.
                p_ptr%update_frac       = p_ptr%sgd_batch_frac
                ctrl%l_sample_updates   = .true.
                ctrl%l_frac_restore     = .false.
                ctrl%l_partial_sums     = .false.
            endif
            ctrl%l_ctf = b_ptr%spproj%get_ctfflag('ptcl2D',iptcl=p_ptr%fromp) .ne. 'no'
        end subroutine init_ctrl

        subroutine sample_particles_for_update()
            integer :: nactive
            if( allocated(pinds) ) deallocate(pinds)
            if( ctrl%l_prob_align )then
                ! prob_align2D owns the outer subset sampling in probabilistic mode;
                ! cluster2D only reproduces that same subset for the downstream update.
                call b_ptr%spproj_field%sample4update_reprod([p_ptr%fromp,p_ptr%top], nptcls2update, pinds)
            else
                call sample_ptcls4update2D(p_ptr, b_ptr, [p_ptr%fromp,p_ptr%top], ctrl%l_sample_updates, nptcls2update, pinds)
            endif
            if( ctrl%l_joint_topk )then
                nactive = b_ptr%spproj_field%count_state_gt_zero()
                if( nactive > 0 ) p_ptr%update_frac = real(nptcls2update) / real(nactive)
            endif
        end subroutine sample_particles_for_update

        subroutine compute_neigh_frac(neighfrac)
            real, intent(out) :: neighfrac
            neighfrac = 0.0
            if( p_ptr%extr_iter > p_ptr%extr_lim )then
                ! done
            else
                if( ctrl%l_snhc )then
                    neighfrac = extremal_decay2D( p_ptr%extr_iter, p_ptr%extr_lim )
                    if( L_VERBOSE_GLOB ) write(logfhandle,'(A,F8.2)') &
                        '>>> STOCHASTIC NEIGHBOURHOOD SIZE(%):', 100.0*(1.0-neighfrac)
                endif
            endif
        end subroutine compute_neigh_frac

        subroutine prepare_batches()
            batchsz_max = min(nptcls2update, p_ptr%nthr * BATCHTHRSZ)
            nbatches    = ceiling(real(nptcls2update) / real(batchsz_max))
            batches     = split_nobjs_even(nptcls2update, nbatches)
            batchsz_max = maxval(batches(:,2) - batches(:,1) + 1)
            allocate(incr_shifts(2,batchsz_max), source=0.0)
        end subroutine prepare_batches

        subroutine ensure_even_odd_partition()
            if( b_ptr%spproj_field%get_nevenodd() == 0 )then
                if( l_distr_worker_glob ) THROW_HARD('no eo partitioning available; cluster2D_exec')
                call b_ptr%spproj_field%partition_eo
                call b_ptr%spproj%write_segment_inside(p_ptr%oritype)
            endif
        end subroutine ensure_even_odd_partition

        subroutine prepare_class_averages_and_restoration()
            call cavger_new(p_ptr, b_ptr)
            if( .not. cline%defined('refs') )then
                THROW_HARD('need refs to be part of command line for cluster2D execution')
            endif
            if( ctrl%l_joint_topk )then
                ! Joint SGD is intentionally one-iteration-lagged block-coordinate:
                ! all scoring and batch updates use refs loaded here, and restored
                ! cavgs are written for the next iteration rather than reloaded mid-run.
                call joint_ref_policy%new(p_ptr%refs%to_char(), p_ptr%which_iter)
                call joint_ref_policy%require_input_refs('cluster2D')
                call joint_ref_policy%write_diag('cluster2D')
            endif
            call cavger_read_all
            ctrl%l_partial_sums = ctrl%l_frac_restore .or. &
                (p_ptr%l_sgd .and. (trim(p_ptr%sgd_mode) == 'cavg_only'))
            call cavger_init_online(batchsz_max, ctrl%l_frac_restore)
        end subroutine prepare_class_averages_and_restoration

        subroutine prepare_alignment_references(batchsz_max)
            integer, intent(in) :: batchsz_max
            if( str_has_substr(ctrl%refine_flag, '_many') )then
                call prep_pftc4align2D(p_ptr, b_ptr, ptcl_match_imgs_pad, batchsz_max, which_iter, ctrl%l_stream,&
                                        &nmany_refs=s2D%snhc_nrefs_bound)
            else
                call prep_pftc4align2D(p_ptr, b_ptr, ptcl_match_imgs_pad, batchsz_max, which_iter, ctrl%l_stream)
            endif
        end subroutine prepare_alignment_references

        subroutine build_batch_particles_local()
            if( ctrl%do_bench ) t_build_batch_particles2D = tic()
            call build_batch_particles2D(p_ptr, b_ptr, batchsz, pinds(batch_start:batch_end), &
                ptcl_imgs, ptcl_match_imgs, ptcl_match_imgs_pad)
            if( ctrl%do_bench ) rt_build_batch_particles2D = rt_build_batch_particles2D + toc(t_build_batch_particles2D)
        end subroutine build_batch_particles_local

        subroutine read_joint_topk_candidates()
            integer :: iptcl_map
            character(len=STDLEN) :: cand_fname
            if( l_distr_worker_glob )then
                cand_fname = joint2D_candidate_part_fname(p_ptr%part, p_ptr%numlen)
                write(logfhandle,'(A,A)') '>>> JOINT 2D SGD: reading distributed top-K candidate table ',&
                    &trim(cand_fname)
                call joint_topk_candidates%read_part_table(p_ptr%part, p_ptr%numlen)
                call joint_topk_candidates%write_distributed_diag('cluster2D read-part', p_ptr%part, p_ptr%nparts)
            else
                write(logfhandle,'(A,A)') '>>> JOINT 2D SGD: reading top-K candidate table ', JOINT2D_CANDIDATES_FNAME
                call joint_topk_candidates%read_table(JOINT2D_CANDIDATES_FNAME)
                call joint_topk_candidates%write_distributed_diag('cluster2D read-global', 0, p_ptr%nparts)
            endif
            if( size(joint_topk_candidates%ncand) /= nptcls2update )then
                THROW_HARD('joint 2D top-K candidate table particle count does not match cluster2D batch set')
            endif
            if( count(joint_topk_candidates%accepted) == 0 )then
                write(logfhandle,'(A)')&
                    &'>>> JOINT2D SGD: provisional soft acceptance is zero; refining all eligible particles'
            endif
            do iptcl_map = 1, nptcls2update
                if( joint_topk_candidates%pinds(iptcl_map) > 0 )then
                    if( joint_topk_candidates%pinds(iptcl_map) /= pinds(iptcl_map) )then
                        THROW_HARD('joint 2D top-K candidate table does not match sampled particle order')
                    endif
                else if( joint_topk_candidates%ncand(iptcl_map) > 0 )then
                    if( joint_topk_candidates%cand(1,iptcl_map)%pind /= pinds(iptcl_map) )then
                        THROW_HARD('joint 2D top-K candidate table does not match sampled particle order')
                    endif
                else
                    THROW_HARD('joint 2D top-K candidate table does not match sampled particle order')
                endif
            end do
            call joint_topk_candidates%write_diag('cluster2D provisional reliability', iteration=p_ptr%which_iter)
        end subroutine read_joint_topk_candidates

        subroutine write_refined_joint_topk_candidates()
            if( .not. allocated(joint_topk_candidates%ncand) ) return
            if( l_distr_worker_glob )then
                call joint_topk_candidates%write_part_table(p_ptr%part, p_ptr%numlen, refined=.true.)
                call joint_topk_candidates%write_distributed_diag('cluster2D write-refined-part',&
                    &p_ptr%part, p_ptr%nparts)
            else
                call joint_topk_candidates%write_distributed_diag('cluster2D final-shared', 0, p_ptr%nparts)
            endif
        end subroutine write_refined_joint_topk_candidates

        subroutine export_joint_topk_for_batch()
            if( .not. ctrl%l_joint_topk ) return
            call joint_topk_candidates%export_batch(batch_start, batch_end, joint_topk_refs,&
                &joint_topk_weights, joint_topk_ncands)
        end subroutine export_joint_topk_for_batch

        subroutine refine_joint_topk_inpls_for_batch()
            real, allocatable :: inpl_scores(:,:), inpl_dists(:,:)
            integer :: cand_count_t(nthr_glob), changed_t(nthr_glob), nonfinite_t(nthr_glob)
            integer :: hard_churn_t(nthr_glob), negative_delta_t(nthr_glob), invalid_t(nthr_glob)
            real    :: loss_delta_sum_t(nthr_glob), loss_delta_max_t(nthr_glob)
            real    :: angle_delta_sum_t(nthr_glob), angle_delta_max_t(nthr_glob)
            integer :: iloc, iptcl_map, iptcl, irank, ithr, nc, nrots, old_inpl, new_inpl
            integer :: eligible_batch, cand_batch, hard_before, hard_after
            integer :: nonfinite_total, invalid_total, changed_total, cand_total, hard_churn_total, negative_total
            real    :: cand_shift(2), score_shift(2), rotmat(2,2), refined_dist, old_dist, loss_delta
            real    :: mean_loss_delta, mean_angle_delta, angle_delta
            logical :: updated

            if( .not. ctrl%l_joint_topk ) return
            if( .not. allocated(joint_topk_candidates%ncand) )then
                THROW_HARD('joint 2D in-plane refinement requested before top-K table was read')
            endif
            nrots = b_ptr%pftc%get_nrots()
            if( nrots < 1 ) THROW_HARD('joint 2D in-plane refinement requires initialized PFTC rotations')
            eligible_batch = 0
            cand_batch     = 0
            do iptcl_map = batch_start, batch_end
                if( joint_topk_candidates%ncand(iptcl_map) < 1 ) cycle
                eligible_batch = eligible_batch + 1
                cand_batch     = cand_batch + joint_topk_candidates%ncand(iptcl_map)
            end do
            if( cand_batch < 1 )then
                write(logfhandle,'(A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
                    &'>>> JOINT2D SGD INPL:', 'batch=', ibatch, 'eligible=', eligible_batch,&
                    &'candidates=', cand_batch, 'changed=', 0
                return
            endif

            allocate(inpl_scores(nrots,nthr_glob), inpl_dists(nrots,nthr_glob), source=0.)
            cand_count_t      = 0
            changed_t         = 0
            nonfinite_t       = 0
            hard_churn_t      = 0
            negative_delta_t  = 0
            invalid_t         = 0
            loss_delta_sum_t  = 0.
            loss_delta_max_t  = 0.
            angle_delta_sum_t = 0.
            angle_delta_max_t = 0.
            !$omp parallel do private(iloc,iptcl_map,iptcl,irank,ithr,nc,hard_before,hard_after,old_inpl,new_inpl)&
            !$omp private(cand_shift,score_shift,rotmat,refined_dist,old_dist,loss_delta,angle_delta,updated)&
            !$omp default(shared) schedule(static) proc_bind(close)
            do iloc = 1, batchsz
                ithr = omp_get_thread_num() + 1
                iptcl_map = batch_start + iloc - 1
                iptcl     = pinds(iptcl_map)
                nc = joint_topk_candidates%ncand(iptcl_map)
                if( nc < 1 ) cycle
                hard_before = joint_topk_candidates%hard_rank(iptcl_map)
                do irank = 1, nc
                    cand_count_t(ithr) = cand_count_t(ithr) + 1
                    old_inpl = joint_topk_candidates%cand(irank,iptcl_map)%inpl
                    if( joint_topk_candidates%cand(irank,iptcl_map)%icls < 1 .or.&
                        &old_inpl < 1 .or. old_inpl > nrots )then
                        invalid_t(ithr) = invalid_t(ithr) + 1
                        cycle
                    endif
                    old_dist = joint_topk_candidates%cand(irank,iptcl_map)%dist
                    cand_shift = 0.
                    if( p_ptr%l_doshift .and. joint_topk_candidates%cand(irank,iptcl_map)%has_sh )then
                        cand_shift = [joint_topk_candidates%cand(irank,iptcl_map)%x,&
                            &joint_topk_candidates%cand(irank,iptcl_map)%y]
                    endif
                    score_shift = 0.
                    if( p_ptr%l_doshift .and. joint_topk_candidates%cand(irank,iptcl_map)%has_sh )then
                        call rotmat2d(b_ptr%pftc%get_rot(old_inpl), rotmat)
                        score_shift = matmul(cand_shift, transpose(rotmat))
                    endif
                    call b_ptr%pftc%gen_objfun_vals(joint_topk_candidates%cand(irank,iptcl_map)%icls,&
                        &iptcl, score_shift, inpl_scores(:,ithr))
                    inpl_dists(:,ithr) = eulprob_dist_switch(inpl_scores(:,ithr), p_ptr%cc_objfun)
                    if( trim(p_ptr%sgd_likelihood_units) == 'gaussian_nll' .and.&
                        &p_ptr%cc_objfun == OBJFUN_EUCLID .and. .not. p_ptr%l_objfun_den )&
                        &inpl_dists(:,ithr) = b_ptr%pftc%get_euclid_nll_scale(iptcl) * inpl_dists(:,ithr)
                    if( any(inpl_scores(:,ithr) /= inpl_scores(:,ithr)) .or.&
                        &any(abs(inpl_scores(:,ithr)) >= huge(1.0) / 2.0) .or.&
                        &any(inpl_dists(:,ithr) /= inpl_dists(:,ithr)) .or.&
                        &any(abs(inpl_dists(:,ithr)) >= huge(1.0) / 2.0) )then
                        nonfinite_t(ithr) = nonfinite_t(ithr) + 1
                        cycle
                    endif
                    new_inpl = minloc(inpl_dists(:,ithr), dim=1)
                    if( new_inpl < 1 .or. new_inpl > nrots )then
                        invalid_t(ithr) = invalid_t(ithr) + 1
                        cycle
                    endif
                    refined_dist = inpl_dists(new_inpl,ithr)
                    angle_delta  = inpl_angle_delta(old_inpl, new_inpl)
                    loss_delta   = old_dist - refined_dist
                    call joint_topk_candidates%apply_inpl_refinement(iptcl_map, irank, new_inpl, refined_dist,&
                        &old_inpl=old_inpl, updated=updated)
                    if( updated )then
                        if( new_inpl /= old_inpl ) changed_t(ithr) = changed_t(ithr) + 1
                        if( loss_delta < 0. ) negative_delta_t(ithr) = negative_delta_t(ithr) + 1
                        loss_delta_sum_t(ithr)  = loss_delta_sum_t(ithr) + loss_delta
                        loss_delta_max_t(ithr)  = max(loss_delta_max_t(ithr), loss_delta)
                        angle_delta_sum_t(ithr) = angle_delta_sum_t(ithr) + angle_delta
                        angle_delta_max_t(ithr) = max(angle_delta_max_t(ithr), angle_delta)
                    endif
                end do
                hard_after = joint_topk_candidates%hard_rank(iptcl_map)
                if( hard_before > 0 .and. hard_after > 0 .and. hard_before /= hard_after )then
                    hard_churn_t(ithr) = hard_churn_t(ithr) + 1
                endif
            end do
            !$omp end parallel do

            cand_total       = sum(cand_count_t)
            changed_total    = sum(changed_t)
            nonfinite_total  = sum(nonfinite_t)
            invalid_total    = sum(invalid_t)
            hard_churn_total = sum(hard_churn_t)
            negative_total   = sum(negative_delta_t)
            mean_loss_delta  = 0.
            mean_angle_delta = 0.
            if( cand_total > 0 )then
                mean_loss_delta  = sum(loss_delta_sum_t) / real(cand_total)
                mean_angle_delta = sum(angle_delta_sum_t) / real(cand_total)
            endif
            deallocate(inpl_scores, inpl_dists)
            write(logfhandle,'(A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
                &'>>> JOINT2D SGD INPL:', 'batch=', ibatch, 'eligible=', eligible_batch,&
                &'candidates=', cand_total, 'changed=', changed_total, 'invalid=', invalid_total,&
                &'nonfinite=', nonfinite_total, 'negative_delta=', negative_total
            write(logfhandle,'(A,1X,A,ES12.4,1X,A,ES12.4)')&
                &'>>> JOINT2D SGD INPL LOSSES:', 'loss_delta_mean=', mean_loss_delta,&
                &'loss_delta_max=', maxval(loss_delta_max_t)
            write(logfhandle,'(A,1X,A,I0,1X,A,ES12.4,1X,A,ES12.4)')&
                &'>>> JOINT2D SGD INPL HARD:', 'winner_churn=', hard_churn_total,&
                &'angle_delta_mean=', mean_angle_delta, 'angle_delta_max=', maxval(angle_delta_max_t)
            if( nonfinite_total > 0 )then
                THROW_HARD('joint 2D in-plane refinement produced nonfinite diagnostics')
            endif
        end subroutine refine_joint_topk_inpls_for_batch

        subroutine refine_joint_topk_shifts_for_batch()
            type(pftc_shsrch_grad) :: grad_shsrch_obj(nthr_glob)
            integer :: cand_count_t(nthr_glob), refined_t(nthr_glob), invalid_t(nthr_glob)
            integer :: no_better_t(nthr_glob), nonfinite_t(nthr_glob), hard_churn_t(nthr_glob)
            real    :: step_sum_t(nthr_glob), step_max_t(nthr_glob), loss_delta_sum_t(nthr_glob)
            real    :: loss_delta_max_t(nthr_glob), winner_shift_sum_t(nthr_glob), winner_shift_max_t(nthr_glob)
            real    :: lims(2,2), lims_init(2,2), mean_step, mean_loss_delta, mean_winner_shift
            integer :: iloc, iptcl_map, iptcl, irank, ithr, nc, irot, hard_before, hard_after
            integer :: eligible_batch, cand_batch, refined_total, nonfinite_total, ithr_init
            integer :: invalid_total, no_better_total, hard_churn_total
            real    :: cxy(3), old_shift(2), old_shift_opt(2), opt_shift(2), damped_shift(2)
            real    :: score_shift(2), rotmat(2,2), refined_corr, refined_dist, old_dist, step
            real    :: loss_delta, winner_shift(2)
            logical :: updated

            if( .not. ctrl%l_joint_topk ) return
            if( .not. allocated(joint_topk_candidates%ncand) )then
                THROW_HARD('joint 2D shift refinement requested before top-K table was read')
            endif
            eligible_batch = 0
            cand_batch     = 0
            do iptcl_map = batch_start, batch_end
                if( joint_topk_candidates%ncand(iptcl_map) < 1 ) cycle
                eligible_batch = eligible_batch + 1
                cand_batch     = cand_batch + joint_topk_candidates%ncand(iptcl_map)
            end do
            if( cand_batch < 1 )then
                write(logfhandle,'(A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
                    &'>>> JOINT2D SGD SHIFT:', 'batch=', ibatch, 'eligible=', eligible_batch,&
                    &'candidates=', cand_batch, 'refined=', 0
                return
            endif
            if( .not. p_ptr%l_doshift )then
                write(logfhandle,'(A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
                    &'>>> JOINT2D SGD SHIFT:', 'batch=', ibatch, 'eligible=', eligible_batch,&
                    &'candidates=', cand_batch, 'refined=', 0
                write(logfhandle,'(A,1X,A)') '>>> JOINT2D SGD SHIFT HARD:', 'shift search disabled'
                return
            endif

            lims(:,1)      = -p_ptr%trs
            lims(:,2)      =  p_ptr%trs
            lims_init(:,1) = -SHC_INPL_TRSHWDTH
            lims_init(:,2) =  SHC_INPL_TRSHWDTH
            do ithr_init = 1, nthr_glob
                call grad_shsrch_obj(ithr_init)%new(b_ptr, lims, lims_init=lims_init,&
                    &maxits=p_ptr%maxits_sh, opt_angle=.false.)
            end do

            cand_count_t       = 0
            refined_t          = 0
            invalid_t          = 0
            no_better_t        = 0
            nonfinite_t        = 0
            hard_churn_t       = 0
            step_sum_t         = 0.
            step_max_t         = 0.
            loss_delta_sum_t   = 0.
            loss_delta_max_t   = 0.
            winner_shift_sum_t = 0.
            winner_shift_max_t = 0.
            !$omp parallel do private(iloc,iptcl_map,iptcl,irank,ithr,nc,irot,hard_before,hard_after,cxy)&
            !$omp private(old_shift,old_shift_opt,opt_shift,damped_shift,score_shift,rotmat)&
            !$omp private(refined_corr,refined_dist,old_dist,step,loss_delta,winner_shift,updated)&
            !$omp default(shared) schedule(static) proc_bind(close)
            do iloc = 1, batchsz
                ithr = omp_get_thread_num() + 1
                iptcl_map = batch_start + iloc - 1
                iptcl     = pinds(iptcl_map)
                nc = joint_topk_candidates%ncand(iptcl_map)
                if( nc < 1 ) cycle
                hard_before = joint_topk_candidates%hard_rank(iptcl_map)
                do irank = 1, nc
                    cand_count_t(ithr) = cand_count_t(ithr) + 1
                    if( joint_topk_candidates%cand(irank,iptcl_map)%icls < 1 .or.&
                        &joint_topk_candidates%cand(irank,iptcl_map)%inpl < 1 )then
                        invalid_t(ithr) = invalid_t(ithr) + 1
                        cycle
                    endif
                    irot      = joint_topk_candidates%cand(irank,iptcl_map)%inpl
                    old_dist  = joint_topk_candidates%cand(irank,iptcl_map)%dist
                    old_shift = 0.
                    if( joint_topk_candidates%cand(irank,iptcl_map)%has_sh )then
                        old_shift = [joint_topk_candidates%cand(irank,iptcl_map)%x,&
                            &joint_topk_candidates%cand(irank,iptcl_map)%y]
                    endif
                    call rotmat2d(b_ptr%pftc%get_rot(irot), rotmat)
                    old_shift_opt = matmul(old_shift, transpose(rotmat))
                    call grad_shsrch_obj(ithr)%set_indices(joint_topk_candidates%cand(irank,iptcl_map)%icls, iptcl)
                    cxy = grad_shsrch_obj(ithr)%minimize(irot=irot, sh_rot=.true., xy_in=old_shift_opt)
                    if( irot <= 0 )then
                        no_better_t(ithr) = no_better_t(ithr) + 1
                        cycle
                    endif
                    opt_shift    = cxy(2:3)
                    damped_shift = old_shift + p_ptr%sgd_eta_shift * (opt_shift - old_shift)
                    score_shift  = matmul(damped_shift, transpose(rotmat))
                    refined_corr = real(b_ptr%pftc%gen_corr_for_rot_8(&
                        &joint_topk_candidates%cand(irank,iptcl_map)%icls, iptcl, real(score_shift,dp), irot))
                    refined_dist = eulprob_dist_switch(refined_corr, p_ptr%cc_objfun)
                    if( trim(p_ptr%sgd_likelihood_units) == 'gaussian_nll' .and.&
                        &p_ptr%cc_objfun == OBJFUN_EUCLID .and. .not. p_ptr%l_objfun_den )&
                        &refined_dist = b_ptr%pftc%get_euclid_nll_scale(iptcl) * refined_dist
                    if( .not. finite_joint_real(refined_corr) .or. .not. finite_joint_real(refined_dist) .or.&
                        &.not. finite_joint_real(opt_shift(1)) .or. .not. finite_joint_real(opt_shift(2)) )then
                        nonfinite_t(ithr) = nonfinite_t(ithr) + 1
                        cycle
                    endif
                    call joint_topk_candidates%apply_shift_refinement(iptcl_map, irank, opt_shift, refined_dist,&
                        &p_ptr%sgd_eta_shift, old_shift=old_shift,&
                        &new_shift=damped_shift, step_norm=step, updated=updated)
                    if( updated )then
                        refined_t(ithr) = refined_t(ithr) + 1
                        loss_delta = old_dist - refined_dist
                        step_sum_t(ithr)       = step_sum_t(ithr) + step
                        step_max_t(ithr)       = max(step_max_t(ithr), step)
                        loss_delta_sum_t(ithr) = loss_delta_sum_t(ithr) + loss_delta
                        loss_delta_max_t(ithr) = max(loss_delta_max_t(ithr), loss_delta)
                    endif
                end do
                hard_after = joint_topk_candidates%hard_rank(iptcl_map)
                if( hard_before > 0 .and. hard_after > 0 .and. hard_before /= hard_after )then
                    hard_churn_t(ithr) = hard_churn_t(ithr) + 1
                endif
                winner_shift = 0.
                if( hard_after > 0 )then
                    if( joint_topk_candidates%cand(hard_after,iptcl_map)%has_sh )then
                        winner_shift = [joint_topk_candidates%cand(hard_after,iptcl_map)%x,&
                            &joint_topk_candidates%cand(hard_after,iptcl_map)%y]
                    endif
                    winner_shift_sum_t(ithr) = winner_shift_sum_t(ithr) + sqrt(sum(winner_shift * winner_shift))
                    winner_shift_max_t(ithr) = max(winner_shift_max_t(ithr), sqrt(sum(winner_shift * winner_shift)))
                endif
            end do
            !$omp end parallel do

            do ithr_init = 1, nthr_glob
                call grad_shsrch_obj(ithr_init)%kill
            end do
            refined_total    = sum(refined_t)
            nonfinite_total  = sum(nonfinite_t)
            invalid_total    = sum(invalid_t)
            no_better_total  = sum(no_better_t)
            hard_churn_total = sum(hard_churn_t)
            mean_step        = 0.
            mean_loss_delta  = 0.
            mean_winner_shift = 0.
            if( refined_total > 0 )then
                mean_step       = sum(step_sum_t) / real(refined_total)
                mean_loss_delta = sum(loss_delta_sum_t) / real(refined_total)
            endif
            if( eligible_batch > 0 ) mean_winner_shift = sum(winner_shift_sum_t) / real(eligible_batch)
            write(logfhandle,'(A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
                &'>>> JOINT2D SGD SHIFT:', 'batch=', ibatch, 'eligible=', eligible_batch,&
                &'candidates=', sum(cand_count_t), 'refined=', refined_total, 'no_better=', no_better_total,&
                &'invalid=', invalid_total, 'nonfinite=', nonfinite_total
            write(logfhandle,'(A,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4)')&
                &'>>> JOINT2D SGD SHIFT NORMS:', 'step_mean=', mean_step, 'step_max=', maxval(step_max_t),&
                &'loss_delta_mean=', mean_loss_delta, 'loss_delta_max=', maxval(loss_delta_max_t)
            write(logfhandle,'(A,1X,A,I0,1X,A,ES12.4,1X,A,ES12.4)')&
                &'>>> JOINT2D SGD SHIFT HARD:', 'winner_churn=', hard_churn_total,&
                &'winner_shift_mean=', mean_winner_shift, 'winner_shift_max=', maxval(winner_shift_max_t)
            if( nonfinite_total > 0 )then
                THROW_HARD('joint 2D shift refinement produced nonfinite diagnostics')
            endif
        end subroutine refine_joint_topk_shifts_for_batch

        subroutine sync_joint_hard_assignments( first_ptcl, last_ptcl )
            integer, intent(in) :: first_ptcl, last_ptcl
            integer :: iptcl_map, iptcl, hard
            real    :: cand_shift(2), total_shift(2), corr, e3

            do iptcl_map = first_ptcl, last_ptcl
                iptcl     = pinds(iptcl_map)
                if( joint_topk_candidates%particle_weight(iptcl_map) <= 0. ) cycle
                hard = joint_topk_candidates%hard_rank(iptcl_map)
                if( hard < 1 ) cycle
                cand_shift = 0.
                if( joint_topk_candidates%cand(hard,iptcl_map)%has_sh )then
                    cand_shift = [joint_topk_candidates%cand(hard,iptcl_map)%x,&
                        &joint_topk_candidates%cand(hard,iptcl_map)%y]
                endif
                total_shift = joint_topk_candidates%base_shift(:,iptcl_map) + cand_shift
                corr = eulprob_corr_switch(joint_topk_candidates%cand(hard,iptcl_map)%dist, p_ptr%cc_objfun)
                if( .not. finite_joint_real(total_shift(1)) .or. .not. finite_joint_real(total_shift(2)) .or.&
                    &.not. finite_joint_real(corr) )then
                    THROW_HARD('joint 2D shift refinement produced nonfinite hard assignment')
                endif
                e3 = 360. - b_ptr%pftc%get_rot(joint_topk_candidates%cand(hard,iptcl_map)%inpl)
                call b_ptr%spproj_field%e3set(iptcl, e3)
                call b_ptr%spproj_field%set_shift(iptcl, total_shift)
                call b_ptr%spproj_field%set(iptcl, 'shincarg', arg(cand_shift))
                call b_ptr%spproj_field%set(iptcl, 'inpl', real(joint_topk_candidates%cand(hard,iptcl_map)%inpl))
                call b_ptr%spproj_field%set(iptcl, 'class', real(joint_topk_candidates%cand(hard,iptcl_map)%icls))
                call b_ptr%spproj_field%set(iptcl, 'corr', corr)
                call b_ptr%spproj_field%set(iptcl, 'frac', 100.)
                call b_ptr%spproj_field%set(iptcl, 'npeaks', real(joint_topk_candidates%ncand(iptcl_map)))
            end do
        end subroutine sync_joint_hard_assignments

        subroutine allocate_strategy_for_particle(iptcl, iptcl_batch)
            integer, intent(in) :: iptcl, iptcl_batch
            logical :: first_or_unsearched, has_been_searched, l_fresh_start
            has_been_searched = b_ptr%spproj_field%has_been_searched(iptcl)
            l_fresh_start     = is_fresh_2D_start(p_ptr, p_ptr%which_iter)
            first_or_unsearched = l_fresh_start .or. (.not. has_been_searched)
            if( ctrl%l_prob_align )then
                allocate(strategy2D_prob :: strategy2Dsrch(iptcl_batch)%ptr)
            else if( ctrl%l_stream )then
                if( first_or_unsearched )then
                    allocate(strategy2D_greedy :: strategy2Dsrch(iptcl_batch)%ptr)
                else
                    select case(trim(ctrl%refine_flag))
                    case('greedy')
                        allocate(strategy2D_greedy         :: strategy2Dsrch(iptcl_batch)%ptr)
                    case('greedy_smpl')
                        allocate(strategy2D_greedy_smpl    :: strategy2Dsrch(iptcl_batch)%ptr)
                    case('snhc_smpl')
                        allocate(strategy2D_snhc_smpl      :: strategy2Dsrch(iptcl_batch)%ptr)
                    case('snhc_smpl_many')
                        allocate(strategy2D_snhc_smpl_many :: strategy2Dsrch(iptcl_batch)%ptr)
                    case default
                        allocate(strategy2D_snhc           :: strategy2Dsrch(iptcl_batch)%ptr)
                    end select
                endif
            else
                if( str_has_substr(ctrl%refine_flag,'inpl') )then
                    if( ctrl%refine_flag == 'inpl' )then
                        allocate(strategy2D_inpl :: strategy2Dsrch(iptcl_batch)%ptr)
                    else if( ctrl%refine_flag == 'inpl_smpl' )then
                        allocate(strategy2D_inpl_smpl :: strategy2Dsrch(iptcl_batch)%ptr)
                    endif
                else if( ctrl%l_greedy .or. first_or_unsearched )then
                    if( trim(p_ptr%tseries) == 'yes' )then
                        if( ctrl%l_np_cls_defined )then
                            allocate(strategy2D_tseries :: strategy2Dsrch(iptcl_batch)%ptr)
                        else
                            allocate(strategy2D_greedy  :: strategy2Dsrch(iptcl_batch)%ptr)
                        endif
                    else
                        select case(trim(ctrl%refine_flag))
                        case('greedy_smpl')
                            allocate(strategy2D_greedy_smpl :: strategy2Dsrch(iptcl_batch)%ptr)
                        case default
                            allocate(strategy2D_greedy      :: strategy2Dsrch(iptcl_batch)%ptr)
                        end select
                    endif
                else
                    select case(trim(ctrl%refine_flag))
                    case('snhc_smpl')
                        allocate(strategy2D_snhc_smpl      :: strategy2Dsrch(iptcl_batch)%ptr)
                    case('snhc_smpl_many')
                        allocate(strategy2D_snhc_smpl_many :: strategy2Dsrch(iptcl_batch)%ptr)
                    case default
                        allocate(strategy2D_snhc           :: strategy2Dsrch(iptcl_batch)%ptr)
                    end select
                endif
            endif
        end subroutine allocate_strategy_for_particle

        subroutine refine_joint_topk_for_batch()
            if( .not. ctrl%l_joint_topk ) return
            call refine_joint_topk_inpls_for_batch()
            call refine_joint_topk_shifts_for_batch()
        end subroutine refine_joint_topk_for_batch

        subroutine finalize_joint_topk_reliability()
            type(joint2D_balance_diag) :: balance_diag
            logical :: fallback_used
            logical :: l_gaussian_nll
            character(len=STDLEN) :: likelihood_units

            l_gaussian_nll = trim(p_ptr%sgd_likelihood_units) == 'gaussian_nll' .and.&
                &p_ptr%cc_objfun == OBJFUN_EUCLID .and. .not. p_ptr%l_objfun_den
            likelihood_units = 'objective_distance'
            if( l_gaussian_nll ) likelihood_units = 'gaussian_nll'
            write(logfhandle,'(A,1X,A,A,1X,A,A,1X,A,L1)')&
                &'>>> JOINT2D SGD LIKELIHOOD UNITS:', 'context=', 'cluster2D_final',&
                &'units=', trim(likelihood_units),&
                &'active=', l_gaussian_nll

            ! Candidate refinements reset logits from their new distances. Re-run
            ! the latent optimizer on the fully refined table, then apply one
            ! balance prior before making the only behavior-controlling gate.
            call joint_topk_candidates%optimize_logits(p_ptr%sgd_inner_its, p_ptr%sgd_eta_latent)
            call joint_topk_candidates%apply_balance_prior(p_ptr%ncls, p_ptr%sgd_balance_weight, balance_diag)
            call joint_topk_candidates%write_balance_diag('cluster2D final', balance_diag)
            call joint_topk_candidates%evaluate_reliability(p_ptr%sgd_cavg_min_cands,&
                &p_ptr%sgd_cavg_max_entropy)
            call joint_topk_candidates%activate_hard_fallback(fallback_used)
            if( count(joint_topk_candidates%particle_weight > 0.) /=&
                &count(joint_topk_candidates%ncand > 0) )then
                THROW_HARD('joint 2D final reliability boundary has missing candidate support')
            endif
            call sync_joint_hard_assignments(1, nptcls2update)
            call joint_topk_candidates%write_diag('cluster2D final reliability', iteration=p_ptr%which_iter)
            write(logfhandle,'(A,1X,A,L1,1X,A,I0,1X,A,I0,1X,A,I0)')&
                &'>>> JOINT2D SGD FINAL UPDATE:', 'fallback=', fallback_used,&
                &'soft_accepted=', count(joint_topk_candidates%accepted),&
                &'contributing=', count(joint_topk_candidates%particle_weight > 0.), 'sampled=', nptcls2update
        end subroutine finalize_joint_topk_reliability

        subroutine accumulate_class_averages_for_batch()
            integer(timer_int_kind) :: t_update
            call export_joint_topk_for_batch()
            call cavger_transf_oridat(batchsz, pinds(batch_start:batch_end), updated_only=.true.)
            if( ctrl%do_bench ) t_update = tic()
            if( ctrl%l_joint_topk )then
                call cavger_update_sums_topk(batchsz, ptcl_imgs(1:batchsz), joint_topk_refs,&
                    &joint_topk_weights, joint_topk_ncands)
            else
                call cavger_update_sums(batchsz, ptcl_imgs(1:batchsz))
            endif
            if( ctrl%do_bench ) rt_cavg_interp_splat = rt_cavg_interp_splat + toc(t_update)
        end subroutine accumulate_class_averages_for_batch

        subroutine cleanup_search_state(strategy2Dsrch, pinds, batches, eulprob_obj_part, batchsz_max, orientation)
            type(strategy2D_per_ptcl), allocatable, intent(inout) :: strategy2Dsrch(:)
            integer, allocatable, intent(inout) :: pinds(:), batches(:,:)
            type(eul_prob_tab2D), intent(inout) :: eulprob_obj_part
            integer,              intent(in)    :: batchsz_max
            type(ori),            intent(inout) :: orientation
            integer :: i
            call clean_strategy2D
            call orientation%kill
            do i = 1, batchsz_max
                nullify(strategy2Dsrch(i)%ptr)
            end do
            call clean_batch_particles2D(b_ptr, ptcl_imgs, ptcl_match_imgs, ptcl_match_imgs_pad)
            deallocate(strategy2Dsrch, pinds, batches)
            if( ctrl%l_prob_align ) call eulprob_obj_part%kill
            call joint_topk_candidates%kill
            if( allocated(joint_topk_refs)    ) deallocate(joint_topk_refs)
            if( allocated(joint_topk_weights) ) deallocate(joint_topk_weights)
            if( allocated(joint_topk_ncands)  ) deallocate(joint_topk_ncands)
            call cavger_dealloc_online
        end subroutine cleanup_search_state

        subroutine write_orientations()
            if( p_ptr%top < p_ptr%fromp )then
                THROW_HARD('invalid output write range in cluster2D_exec: TOP < FROMP')
            endif
            call binwrite_oritab(p_ptr%outfile, b_ptr%spproj, b_ptr%spproj_field, &
                [p_ptr%fromp,p_ptr%top], isegment=PTCL2D_SEG)
            p_ptr%oritab = p_ptr%outfile
        end subroutine write_orientations

        subroutine finalize_restoration_and_convergence(states, cline, conv, which_iter, converged)
            real, allocatable, intent(inout) :: states(:)
            class(cmdline),    intent(inout) :: cline
            type(convergence), intent(inout) :: conv
            integer,           intent(in)    :: which_iter
            logical,           intent(inout) :: converged
            integer :: n_unassigned
            logical :: l_full_assignment
            if( l_distr_worker_glob )then
                if( ctrl%l_restore_cavgs )then
                    call cavger_apply_sgd_update
                    call cavger_readwrite_partial_sums('write')
                endif
                call cavger_kill
            else
                if( ctrl%l_restore_cavgs )then
                    if( cline%defined('which_iter') )then
                        if( ctrl%l_joint_topk )then
                            if( .not. joint_ref_policy%is_one_iteration_lag() )then
                                THROW_HARD('joint 2D SGD reference refresh policy is not one-iteration-lagged')
                            endif
                            p_ptr%refs      = joint_ref_policy%refs_out
                            p_ptr%refs_even = joint_ref_policy%refs_even_out
                            p_ptr%refs_odd  = joint_ref_policy%refs_odd_out
                        else
                            p_ptr%refs      = CAVGS_ITER_FBODY//int2str_pad(p_ptr%which_iter,3)//MRC_EXT
                            p_ptr%refs_even = CAVGS_ITER_FBODY//int2str_pad(p_ptr%which_iter,3)//'_even'//MRC_EXT
                            p_ptr%refs_odd  = CAVGS_ITER_FBODY//int2str_pad(p_ptr%which_iter,3)//'_odd'//MRC_EXT
                        endif
                    else
                        THROW_HARD('which_iter expected to be part of command line in shared-memory execution')
                    endif
                    call cavger_apply_sgd_update
                    call cavger_readwrite_partial_sums('write')
                    call cavger_restore_cavgs( p_ptr%frcs )
                    call cavger_gen2Dclassdoc
                    call cavger_write_merged( p_ptr%refs )
                    call cavger_write_eo( p_ptr%refs_even, p_ptr%refs_odd )
                    call cavger_kill
                    call cline%set('refs', p_ptr%refs)
                    call b_ptr%spproj%os_cls3D%new(p_ptr%ncls, is_ptcl=.false.)
                    states = b_ptr%spproj%os_cls2D%get_all('state')
                    call b_ptr%spproj%os_cls3D%set_all('state',states)
                    call b_ptr%spproj%write_segment_inside('cls2D', p_ptr%projfile)
                    call b_ptr%spproj%write_segment_inside('cls3D', p_ptr%projfile)
                    deallocate(states)
                endif
                converged = conv%check_conv2D(p_ptr, cline, b_ptr%spproj_field, b_ptr%spproj_field%get_n('class'), p_ptr%msk)
                converged = converged .and. (p_ptr%which_iter >= p_ptr%minits)
                converged = converged .or.  (p_ptr%which_iter >= p_ptr%maxits)
                if( ctrl%l_require_full_assignment )then
                    l_full_assignment = all_active_ptcls_2D_assigned(b_ptr%spproj_field, [p_ptr%fromp,p_ptr%top], n_unassigned)
                    if( .not. l_full_assignment )then
                        write(logfhandle,'(A,I8)') &
                            '>>> CLUSTER2D FULL-ASSIGNMENT COVERAGE: UNASSIGNED ACTIVE PARTICLES =', n_unassigned
                    endif
                    converged = converged .and. l_full_assignment
                endif
                if(.not. ctrl%l_stream) call progressfile_update(conv%get('progress'))
            endif
        end subroutine finalize_restoration_and_convergence

        logical function finite_joint_real( val ) result( is_finite )
            real, intent(in) :: val
            is_finite = (val == val) .and. (abs(val) < huge(val) / 2.0)
        end function finite_joint_real

        real function inpl_angle_delta( old_inpl, new_inpl ) result( delta )
            integer, intent(in) :: old_inpl, new_inpl
            delta = 0.
            if( old_inpl < 1 .or. new_inpl < 1 ) return
            delta = abs(b_ptr%pftc%get_rot(new_inpl) - b_ptr%pftc%get_rot(old_inpl))
            if( delta > 180. ) delta = 360. - delta
        end function inpl_angle_delta

        subroutine maybe_write_bench(which_iter)
            use, intrinsic :: iso_fortran_env, only: int64, real64
            integer, intent(in) :: which_iter
            integer(int64) :: peak_rss
            real(real64)    :: peak_rss_gib
            if( .not. ctrl%do_bench ) return
            if( p_ptr%part /= 1 ) return
            rt_tot = toc(t_tot)
            peak_rss = get_peak_rss_bytes()
            peak_rss_gib = -1.0_real64
            if( peak_rss >= 0_int64 ) peak_rss_gib = real(peak_rss,real64) / real(1024_int64**3,real64)
            benchfname = string('CLUSTER2D_BENCH_ITER')//int2str_pad(which_iter,3)//'.txt'
            call fopen(fnr, FILE=benchfname, STATUS='REPLACE', action='WRITE')
            write(fnr,'(a)') '*** BENCHMARK CONTEXT ***'
            write(fnr,'(a,a)')  'match2D refine mode                 : ', trim(ctrl%refine_flag)
            write(fnr,'(a,l1)') 'match2D probabilistic alignment     : ', ctrl%l_prob_align
            write(fnr,'(a,l1)') 'match2D sample updates              : ', ctrl%l_sample_updates
            write(fnr,'(a,l1)') 'match2D restore class averages      : ', ctrl%l_restore_cavgs
            write(fnr,'(a,l1)') 'match2D require full assignment     : ', ctrl%l_require_full_assignment
            write(fnr,'(a,i0)') 'match2D nclasses                    : ', p_ptr%ncls
            write(fnr,'(a,i0)') 'match2D kfrom                       : ', p_ptr%kfromto(1)
            write(fnr,'(a,i0)') 'match2D kto                         : ', p_ptr%kfromto(2)
            write(fnr,'(a,i0)') 'match2D process partition           : ', p_ptr%part
            write(fnr,'(a,i0)') 'match2D process pid                 : ', p_ptr%pid
            write(fnr,'(a,i0)') 'match2D peak RSS (bytes)            : ', peak_rss
            write(fnr,'(a,f0.3)') 'match2D peak RSS (GiB)              : ', peak_rss_gib
            write(fnr,'(a)') ''
            write(fnr,'(a)') '*** TIMINGS (s) ***'
            write(fnr,'(a,1x,f0.2)') 'match2D startup/setup               :', rt_startup
            write(fnr,'(a,1x,f0.2)') 'match2D particle allocation         :', rt_alloc_ptcl_imgs2D
            write(fnr,'(a,1x,f0.2)') 'match2D reference preparation       :', rt_prep_pftc_refs2D
            write(fnr,'(a,1x,f0.2)') 'match2D particle preparation        :', rt_build_batch_particles2D
            write(fnr,'(a,1x,f0.2)') 'match2D alignment search            :', rt_align
            write(fnr,'(a,1x,f0.2)') 'match2D class averaging             :', rt_cavg
            write(fnr,'(a,1x,f0.2)') 'match2D cavg FFT/CTF/interpolation  :', rt_cavg_interp_splat
            write(fnr,'(a,1x,f0.2)') 'match2D total time                  :', rt_tot
            write(fnr,'(a,1x,f0.2)') 'match2D % accounted for             :', &
                ((rt_startup + rt_alloc_ptcl_imgs2D + rt_prep_pftc_refs2D + rt_build_batch_particles2D + &
                  rt_align + rt_cavg) / rt_tot) * 100.

            call fclose(fnr)
        end subroutine maybe_write_bench

    end subroutine cluster2D_exec

    subroutine display( self )
        class(cluster2D_ctrl), intent(in) :: self
        write(logfhandle,'(a)') '>>> CLUSTER2D CONTROL FLAGS:'
        write(logfhandle,'(a,a)') 'refine_flag           : ', trim(self%refine_flag)
        write(logfhandle,'(a,l1)') 'l_sample_updates     : ', self%l_sample_updates
        write(logfhandle,'(a,l1)') 'l_frac_restore       : ', self%l_frac_restore
        write(logfhandle,'(a,l1)') 'l_partial_sums       : ', self%l_partial_sums
        write(logfhandle,'(a,l1)') 'l_ctf                : ', self%l_ctf
        write(logfhandle,'(a,l1)') 'l_snhc               : ', self%l_snhc
        write(logfhandle,'(a,l1)') 'l_stream             : ', self%l_stream
        write(logfhandle,'(a,l1)') 'l_greedy             : ', self%l_greedy
        write(logfhandle,'(a,l1)') 'l_np_cls_defined     : ', self%l_np_cls_defined
        write(logfhandle,'(a,l1)') 'l_prob_align         : ', self%l_prob_align
        write(logfhandle,'(a,l1)') 'l_joint_topk         : ', self%l_joint_topk
        write(logfhandle,'(a,l1)') 'l_restore_cavgs      : ', self%l_restore_cavgs
        write(logfhandle,'(a,l1)') 'l_require_full_assignment : ', self%l_require_full_assignment
        write(logfhandle,'(a,l1)') 'do_bench             : ', self%do_bench
    end subroutine display

end module simple_strategy2D_matcher
