!@descr: Compact top-K candidate table for 2D joint-SGD latent updates
module simple_strategy2D_joint_sgd_candidates
use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
use simple_core_module_api
use simple_type_defs, only: ptcl_ref
use simple_eul_prob_tab_utils, only: materialize_seed_shift
implicit none

public :: joint2D_candidate, joint2D_balance_diag, joint2D_candidate_table, JOINT2D_CANDIDATES_FNAME
public :: joint2D_candidate_part_fname
private

#include "simple_local_flags.inc"

character(len=*), parameter :: JOINT2D_CANDIDATES_FNAME = 'joint2D_topk_candidates.dat'
integer,          parameter :: JOINT2D_CANDIDATES_VERSION = 5
integer,          parameter :: SHIFT_PROVENANCE_INVALID       = 0
integer,          parameter :: SHIFT_PROVENANCE_CLASS_REFINED = 1
integer,          parameter :: SHIFT_PROVENANCE_SEED          = 2
integer,          parameter :: SHIFT_PROVENANCE_ZERO          = 3
integer,          parameter :: RELIABILITY_OK           = 0
integer,          parameter :: RELIABILITY_EMPTY        = 1
integer,          parameter :: RELIABILITY_TOO_FEW      = 2
integer,          parameter :: RELIABILITY_HIGH_ENTROPY = 3
real,             parameter :: BALANCE_EPS              = 1.0e-6

type :: joint2D_candidate
    integer :: pind = 0
    integer :: icls = 0
    integer :: inpl = 0
    integer :: rank = 0
    real    :: dist = 0.
    real    :: logit = 0.
    real    :: weight = 0.
    real    :: eff_weight = 0.
    real    :: x = 0.
    real    :: y = 0.
    logical :: has_sh = .false.
    logical :: hard = .false.
end type joint2D_candidate

type :: joint2D_balance_diag
    integer :: nclasses = 0
    integer :: active_classes = 0
    integer :: zero_support_classes = 0
    integer :: eligible_particles = 0
    integer :: empty_particles = 0
    integer :: candidates = 0
    integer :: winner_churn = 0
    integer :: nonfinite = 0
    real    :: balance_weight = 0.
    real    :: support_min = 0.
    real    :: support_mean = 0.
    real    :: support_max = 0.
    real    :: prior_min = 0.
    real    :: prior_max = 0.
    real    :: entropy_before = 0.
    real    :: entropy_after = 0.
end type joint2D_balance_diag

type :: joint2D_candidate_table
    type(joint2D_candidate), allocatable :: cand(:,:)        !< top-K candidates (topk,nptcls)
    integer,                 allocatable :: pinds(:)         !< global particle index per candidate-table column
    integer,                 allocatable :: ncand(:)         !< valid candidates retained per particle
    integer,                 allocatable :: hard_rank(:)     !< selected straight-through rank per particle
    integer,                 allocatable :: initial_hard_rank(:) !< hard rank before latent-logit optimization
    integer,                 allocatable :: reject_reason(:) !< reliability gate reason per particle
    real,                    allocatable :: entropy(:)       !< entropy over retained soft weights
    real,                    allocatable :: initial_entropy(:) !< entropy before latent-logit optimization
    real,                    allocatable :: norm_entropy(:)  !< entropy normalized by log(ncand)
    real,                    allocatable :: winner_weight(:) !< soft weight of the hard winner
    real,                    allocatable :: expected_loss(:) !< current expected candidate loss
    real,                    allocatable :: initial_expected_loss(:) !< expected loss before optimization
    real,                    allocatable :: loss_delta(:)    !< initial_expected_loss - expected_loss
    real,                    allocatable :: particle_weight(:) !< total class-average support; independent of soft acceptance
    real,                    allocatable :: base_shift(:,:)  !< pre-assignment/base shift (2,nptcls)
    real,                    allocatable :: likelihood_scale(:) !< provisional Gaussian-NLL scale retained through refinement
    integer,                 allocatable :: shift_provenance(:,:) !< origin of candidate delta shift (topk,nptcls)
    logical,                 allocatable :: accepted(:)      !< true only for a reliable soft top-K assignment
contains
    procedure :: build_from_loc_tab
    procedure :: materialize_seed_shifts
    procedure :: set_base_shifts
    procedure :: set_likelihood_scales
    procedure :: materialize_candidate_distance
    procedure :: optimize_logits
    procedure :: apply_balance_prior
    procedure :: apply_inpl_refinement
    procedure :: apply_shift_refinement
    procedure :: evaluate_reliability
    procedure :: activate_hard_fallback
    procedure :: apply_reliability
    procedure :: write_hard_assignments
    procedure :: write_table
    procedure :: read_table
    procedure :: write_part_table
    procedure :: read_part_table
    procedure :: extract_by_pinds
    procedure :: merge_parts_by_pinds
    procedure :: records_equal
    procedure :: checksum => candidate_table_checksum
    procedure :: export_batch
    procedure :: write_diag
    procedure :: write_balance_diag
    procedure :: write_distributed_diag
    procedure :: write_shift_provenance_diag
    procedure :: kill => kill_candidate_table
end type joint2D_candidate_table

contains

    function joint2D_candidate_part_fname( part, numlen, refined ) result( fname )
        integer,           intent(in) :: part
        integer,           intent(in) :: numlen
        logical, optional, intent(in) :: refined
        character(len=STDLEN) :: fname
        logical :: l_refined

        if( part < 1 ) THROW_HARD('joint2D_candidate_part_fname: part must be >= 1')
        l_refined = .false.
        if( present(refined) ) l_refined = refined
        if( l_refined )then
            fname = 'joint2D_topk_candidates_refined_part'//int2str_pad(part,max(1,numlen))//'.dat'
        else
            fname = 'joint2D_topk_candidates_part'//int2str_pad(part,max(1,numlen))//'.dat'
        endif
    end function joint2D_candidate_part_fname

    subroutine build_from_loc_tab( self, loc_tab, topk, pinds )
        class(joint2D_candidate_table), intent(inout) :: self
        type(ptcl_ref),                 intent(in)    :: loc_tab(:,:)
        integer,                        intent(in)    :: topk
        integer, optional,              intent(in)    :: pinds(:)
        integer :: icls, iptcl, nclasses, nptcls

        if( topk < 1 ) THROW_HARD('joint2D_candidate_table: topk must be >= 1')

        nclasses = size(loc_tab, 1)
        nptcls   = size(loc_tab, 2)
        call allocate_blank_table(self, topk, nptcls)
        if( present(pinds) )then
            if( size(pinds) /= nptcls ) THROW_HARD('joint2D_candidate_table: pinds size mismatch')
            self%pinds = pinds
        endif

        do iptcl = 1, nptcls
            do icls = 1, nclasses
                if( .not. valid_ref(loc_tab(icls,iptcl)) ) cycle
                call insert_candidate(self, iptcl, topk, loc_tab(icls,iptcl))
            end do
            call finalize_particle(self, iptcl)
        end do
        call recover_column_pinds(self)
        call self%apply_reliability(1, 1.0)
    end subroutine build_from_loc_tab

    subroutine materialize_seed_shifts( self, seed_shifts, seed_has_sh, l_doshift, seed_nrots )
        class(joint2D_candidate_table), intent(inout) :: self
        real,                           intent(in)    :: seed_shifts(:,:)
        logical,                        intent(in)    :: seed_has_sh(:)
        logical,                        intent(in)    :: l_doshift
        integer,                        intent(in)    :: seed_nrots
        type(ptcl_ref) :: ref
        integer :: iptcl, irank

        call require_allocated(self, 'seed-shift materialization requested before build/read')
        if( size(seed_shifts,1) /= 2 .or. size(seed_shifts,2) /= size(self%ncand) .or.&
            &size(seed_has_sh) /= size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: seed-shift table size mismatch')
        endif
        if( l_doshift .and. seed_nrots < 1 )then
            THROW_HARD('joint2D_candidate_table: seed-shift materialization requires positive rotation count')
        endif

        self%shift_provenance = SHIFT_PROVENANCE_INVALID
        do iptcl = 1, size(self%ncand)
            do irank = 1, self%ncand(iptcl)
                if( self%cand(irank,iptcl)%has_sh )then
                    self%shift_provenance(irank,iptcl) = SHIFT_PROVENANCE_CLASS_REFINED
                else if( l_doshift .and. seed_has_sh(iptcl) )then
                    ref = ptcl_ref()
                    ref%inpl = self%cand(irank,iptcl)%inpl
                    call materialize_seed_shift(ref, seed_shifts(:,iptcl), .true., .true., seed_nrots)
                    self%cand(irank,iptcl)%x      = ref%x
                    self%cand(irank,iptcl)%y      = ref%y
                    self%cand(irank,iptcl)%has_sh = ref%has_sh
                    self%shift_provenance(irank,iptcl) = SHIFT_PROVENANCE_SEED
                else
                    self%cand(irank,iptcl)%x      = 0.
                    self%cand(irank,iptcl)%y      = 0.
                    self%cand(irank,iptcl)%has_sh = .false.
                    self%shift_provenance(irank,iptcl) = SHIFT_PROVENANCE_ZERO
                endif
                if( .not. finite_real(self%cand(irank,iptcl)%x) .or.&
                    &.not. finite_real(self%cand(irank,iptcl)%y) )then
                    THROW_HARD('joint2D_candidate_table: nonfinite materialized candidate delta shift')
                endif
            enddo
        enddo
    end subroutine materialize_seed_shifts

    subroutine set_base_shifts( self, base_shift )
        class(joint2D_candidate_table), intent(inout) :: self
        real,                           intent(in)    :: base_shift(:,:)
        integer :: nptcls

        call require_allocated(self, 'base shifts requested before build/read')
        nptcls = size(self%ncand)
        if( size(base_shift, 1) /= 2 .or. size(base_shift, 2) /= nptcls )then
            THROW_HARD('joint2D_candidate_table: base shift size mismatch')
        endif
        self%base_shift = base_shift
    end subroutine set_base_shifts

    subroutine set_likelihood_scales( self, likelihood_scale )
        class(joint2D_candidate_table), intent(inout) :: self
        real,                           intent(in)    :: likelihood_scale(:)

        call require_allocated(self, 'likelihood scales requested before build/read')
        if( size(likelihood_scale) /= size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: likelihood-scale size mismatch')
        endif
        if( any(.not. ieee_is_finite(likelihood_scale)) .or. any(likelihood_scale <= 0.) )then
            THROW_HARD('joint2D_candidate_table: likelihood scales must be finite and positive')
        endif
        self%likelihood_scale = likelihood_scale
    end subroutine set_likelihood_scales

    subroutine materialize_candidate_distance( self, iptcl, irank, dist )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl, irank
        real,                           intent(in)    :: dist

        call require_allocated(self, 'candidate-distance materialization requested before build/read')
        if( iptcl < 1 .or. iptcl > size(self%ncand) .or. irank < 1 .or. irank > self%ncand(iptcl) )then
            THROW_HARD('joint2D_candidate_table: invalid candidate-distance materialization index')
        endif
        if( .not. ieee_is_finite(dist) .or. dist < 0. )then
            THROW_HARD('joint2D_candidate_table: invalid materialized candidate distance')
        endif
        self%cand(irank,iptcl)%dist  = dist
        self%cand(irank,iptcl)%logit = -dist
        call refresh_particle(self, iptcl)
    end subroutine materialize_candidate_distance

    subroutine optimize_logits( self, inner_its, eta_latent )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: inner_its
        real,                           intent(in)    :: eta_latent
        integer :: iter, iptcl

        call require_allocated(self, 'latent-logit optimization requested before build/read')
        if( inner_its < 1 ) THROW_HARD('joint2D_candidate_table: inner_its must be >= 1')
        if( eta_latent <= 0. ) THROW_HARD('joint2D_candidate_table: eta_latent must be > 0')

        do iter = 1, inner_its
            do iptcl = 1, size(self%ncand)
                call optimize_particle_logits(self, iptcl, eta_latent)
                call refresh_particle(self, iptcl)
            end do
        end do
        do iptcl = 1, size(self%ncand)
            if( self%ncand(iptcl) > 0 )then
                self%loss_delta(iptcl) = self%initial_expected_loss(iptcl) - self%expected_loss(iptcl)
            endif
        end do
    end subroutine optimize_logits

    subroutine apply_balance_prior( self, nclasses, balance_weight, diag, first_ptcl, last_ptcl )
        class(joint2D_candidate_table),      intent(inout) :: self
        integer,                             intent(in)    :: nclasses
        real,                                intent(in)    :: balance_weight
        type(joint2D_balance_diag), optional,intent(out)   :: diag
        integer, optional,                   intent(in)    :: first_ptcl
        integer, optional,                   intent(in)    :: last_ptcl
        type(joint2D_balance_diag) :: local_diag
        real, allocatable :: support(:), prior(:)
        integer :: first, last, iptcl, irank, icls, nc, hard_before, k
        real    :: support_total

        call require_allocated(self, 'class-balance prior requested before build/read')
        if( nclasses < 1 ) THROW_HARD('joint2D_candidate_table: nclasses must be >= 1')
        if( balance_weight < 0. ) THROW_HARD('joint2D_candidate_table: balance_weight must be >= 0')

        first = 1
        last  = size(self%ncand)
        if( present(first_ptcl) ) first = first_ptcl
        if( present(last_ptcl)  ) last  = last_ptcl
        if( first < 1 .or. last < first .or. last > size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: invalid class-balance prior particle range')
        endif

        allocate(support(nclasses), prior(nclasses), source=0.)
        local_diag = joint2D_balance_diag()
        local_diag%nclasses       = nclasses
        local_diag%balance_weight = balance_weight

        do iptcl = first, last
            if( self%ncand(iptcl) < 1 ) cycle
            local_diag%eligible_particles = local_diag%eligible_particles + 1
            local_diag%entropy_before = local_diag%entropy_before + self%entropy(iptcl)
            nc = self%ncand(iptcl)
            if( nc < 1 ) cycle
            local_diag%candidates = local_diag%candidates + nc
            do irank = 1, nc
                icls = self%cand(irank,iptcl)%icls
                if( icls < 1 .or. icls > nclasses )then
                    THROW_HARD('joint2D_candidate_table: class-balance prior class index out of range')
                endif
                if( .not. finite_real(self%cand(irank,iptcl)%weight) )then
                    THROW_HARD('joint2D_candidate_table: nonfinite class-balance candidate weight')
                endif
                support(icls) = support(icls) + self%cand(irank,iptcl)%weight
            end do
        end do
        local_diag%empty_particles = (last - first + 1) - local_diag%eligible_particles

        support_total = 0.
        do k = 1, nclasses
            if( support(k) > BALANCE_EPS )then
                local_diag%active_classes = local_diag%active_classes + 1
                support_total = support_total + support(k)
                if( local_diag%active_classes == 1 )then
                    local_diag%support_min = support(k)
                    local_diag%support_max = support(k)
                else
                    local_diag%support_min = min(local_diag%support_min, support(k))
                    local_diag%support_max = max(local_diag%support_max, support(k))
                endif
            endif
        end do
        local_diag%zero_support_classes = nclasses - local_diag%active_classes
        if( local_diag%active_classes > 0 )then
            local_diag%support_mean = support_total / real(local_diag%active_classes)
            local_diag%prior_min = huge(1.0)
            local_diag%prior_max = -huge(1.0)
            do k = 1, nclasses
                if( support(k) <= BALANCE_EPS ) cycle
                prior(k) = balance_weight * log((local_diag%support_mean + BALANCE_EPS)&
                    &/ (support(k) + BALANCE_EPS))
                if( .not. finite_real(prior(k)) )then
                    THROW_HARD('joint2D_candidate_table: nonfinite class-balance prior')
                endif
                local_diag%prior_min = min(local_diag%prior_min, prior(k))
                local_diag%prior_max = max(local_diag%prior_max, prior(k))
            end do
        endif

        if( balance_weight > 0. .and. local_diag%active_classes > 0 )then
            do iptcl = first, last
                if( self%ncand(iptcl) < 1 ) cycle
                nc = self%ncand(iptcl)
                if( nc < 1 ) cycle
                hard_before = self%hard_rank(iptcl)
                do irank = 1, nc
                    icls = self%cand(irank,iptcl)%icls
                    if( support(icls) <= BALANCE_EPS ) cycle
                    self%cand(irank,iptcl)%logit = self%cand(irank,iptcl)%logit + prior(icls)
                    if( .not. finite_real(self%cand(irank,iptcl)%logit) )then
                        THROW_HARD('joint2D_candidate_table: nonfinite class-balance logit')
                    endif
                end do
                call refresh_particle(self, iptcl)
                call require_finite_particle(self, iptcl, 'class-balance prior')
                if( hard_before > 0 .and. self%hard_rank(iptcl) > 0 .and.&
                    &hard_before /= self%hard_rank(iptcl) )then
                    local_diag%winner_churn = local_diag%winner_churn + 1
                endif
            end do
        endif

        do iptcl = first, last
            if( self%ncand(iptcl) < 1 ) cycle
            local_diag%entropy_after = local_diag%entropy_after + self%entropy(iptcl)
        end do
        if( local_diag%eligible_particles > 0 )then
            local_diag%entropy_before = local_diag%entropy_before / real(local_diag%eligible_particles)
            local_diag%entropy_after  = local_diag%entropy_after  / real(local_diag%eligible_particles)
        endif
        if( local_diag%active_classes == 0 )then
            local_diag%prior_min = 0.
            local_diag%prior_max = 0.
        endif

        if( present(diag) ) diag = local_diag
        deallocate(support, prior)
    end subroutine apply_balance_prior

    subroutine apply_inpl_refinement( self, iptcl, irank, new_inpl, refined_dist, old_inpl, updated, refined_shift )
        class(joint2D_candidate_table), intent(inout)        :: self
        integer,                        intent(in)           :: iptcl
        integer,                        intent(in)           :: irank
        integer,                        intent(in)           :: new_inpl
        real,                           intent(in)           :: refined_dist
        integer,              optional, intent(out)          :: old_inpl
        logical,              optional, intent(out)          :: updated
        real,                 optional, intent(in)           :: refined_shift(2)
        integer :: nc, prev_inpl
        real :: old_dist, tol

        call require_allocated(self, 'in-plane refinement requested before build/read')
        if( present(old_inpl) ) old_inpl = 0
        if( present(updated)  ) updated  = .false.
        if( iptcl < 1 .or. iptcl > size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: in-plane refinement particle index out of range')
        endif
        nc = self%ncand(iptcl)
        if( irank < 1 .or. irank > nc )then
            THROW_HARD('joint2D_candidate_table: in-plane refinement candidate rank out of range')
        endif
        if( new_inpl < 1 ) THROW_HARD('joint2D_candidate_table: refined in-plane index must be > 0')
        if( .not. finite_real(refined_dist) )then
            THROW_HARD('joint2D_candidate_table: nonfinite in-plane-refinement distance')
        endif
        if( present(refined_shift) )then
            if( .not. finite_real(refined_shift(1)) .or. .not. finite_real(refined_shift(2)) )then
                THROW_HARD('joint2D_candidate_table: nonfinite in-plane-refinement delta shift')
            endif
        endif

        prev_inpl = self%cand(irank,iptcl)%inpl
        old_dist  = self%cand(irank,iptcl)%dist
        tol = refinement_tolerance(old_dist, refined_dist)
        if( refined_dist >= old_dist - tol )then
            if( present(old_inpl) ) old_inpl = prev_inpl
            return
        endif
        self%cand(irank,iptcl)%inpl  = new_inpl
        self%cand(irank,iptcl)%dist  = refined_dist
        self%cand(irank,iptcl)%logit = -refined_dist
        if( present(refined_shift) )then
            self%cand(irank,iptcl)%x      = refined_shift(1)
            self%cand(irank,iptcl)%y      = refined_shift(2)
            self%cand(irank,iptcl)%has_sh = .true.
        endif
        call refresh_particle(self, iptcl)
        self%loss_delta(iptcl) = self%initial_expected_loss(iptcl) - self%expected_loss(iptcl)

        if( present(old_inpl) ) old_inpl = prev_inpl
        if( present(updated)  ) updated  = .true.
    end subroutine apply_inpl_refinement

    subroutine apply_shift_refinement( self, iptcl, irank, opt_shift, refined_dist, eta_shift,&
            &old_shift, new_shift, step_norm, updated )
        class(joint2D_candidate_table), intent(inout)        :: self
        integer,                        intent(in)           :: iptcl
        integer,                        intent(in)           :: irank
        real,                           intent(in)           :: opt_shift(2)
        real,                           intent(in)           :: refined_dist
        real,                           intent(in)           :: eta_shift
        real,                 optional, intent(out)          :: old_shift(2)
        real,                 optional, intent(out)          :: new_shift(2)
        real,                 optional, intent(out)          :: step_norm
        logical,              optional, intent(out)          :: updated
        real :: cur_shift(2), damped_shift(2), step_vec(2)
        integer :: nc

        call require_allocated(self, 'shift refinement requested before build/read')
        if( present(updated)  ) updated  = .false.
        if( present(old_shift) ) old_shift = 0.
        if( present(new_shift) ) new_shift = 0.
        if( present(step_norm) ) step_norm = 0.
        if( iptcl < 1 .or. iptcl > size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: shift refinement particle index out of range')
        endif
        nc = self%ncand(iptcl)
        if( irank < 1 .or. irank > nc )then
            THROW_HARD('joint2D_candidate_table: shift refinement candidate rank out of range')
        endif
        if( eta_shift <= 0. ) THROW_HARD('joint2D_candidate_table: eta_shift must be > 0')
        if( .not. finite_real(opt_shift(1)) .or. .not. finite_real(opt_shift(2)) .or.&
            &.not. finite_real(refined_dist) )then
            THROW_HARD('joint2D_candidate_table: nonfinite shift-refinement result')
        endif

        cur_shift = 0.
        if( self%cand(irank,iptcl)%has_sh )then
            cur_shift = [self%cand(irank,iptcl)%x, self%cand(irank,iptcl)%y]
        endif
        if( .not. finite_real(cur_shift(1)) .or. .not. finite_real(cur_shift(2)) )then
            THROW_HARD('joint2D_candidate_table: nonfinite candidate shift before refinement')
        endif
        damped_shift = cur_shift + eta_shift * (opt_shift - cur_shift)
        if( .not. finite_real(damped_shift(1)) .or. .not. finite_real(damped_shift(2)) )then
            THROW_HARD('joint2D_candidate_table: nonfinite damped candidate shift')
        endif
        step_vec = damped_shift - cur_shift

        if( refined_dist >= self%cand(irank,iptcl)%dist -&
            &refinement_tolerance(self%cand(irank,iptcl)%dist, refined_dist) )then
            if( present(old_shift) ) old_shift = cur_shift
            if( present(new_shift) ) new_shift = cur_shift
            return
        endif

        self%cand(irank,iptcl)%x      = damped_shift(1)
        self%cand(irank,iptcl)%y      = damped_shift(2)
        self%cand(irank,iptcl)%has_sh = .true.
        self%cand(irank,iptcl)%dist   = refined_dist
        self%cand(irank,iptcl)%logit  = -refined_dist
        call refresh_particle(self, iptcl)
        self%loss_delta(iptcl) = self%initial_expected_loss(iptcl) - self%expected_loss(iptcl)

        if( present(old_shift) ) old_shift = cur_shift
        if( present(new_shift) ) new_shift = damped_shift
        if( present(step_norm) ) step_norm = sqrt(sum(step_vec * step_vec))
        if( present(updated)   ) updated   = .true.
    end subroutine apply_shift_refinement

    subroutine evaluate_reliability( self, min_cands, max_entropy )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: min_cands
        real,                           intent(in)    :: max_entropy
        integer :: iptcl, irank, min_cands_eff, nc, topk
        real    :: norm_h

        call require_allocated(self, 'reliability requested before build/read')
        if( min_cands < 1 ) THROW_HARD('joint2D_candidate_table: min_cands must be >= 1')
        if( max_entropy < 0. .or. max_entropy > 1. )then
            THROW_HARD('joint2D_candidate_table: max_entropy must be between 0 and 1')
        endif
        topk = size(self%cand, 1)
        min_cands_eff = min_cands
        if( topk == 1 ) min_cands_eff = 1

        self%accepted        = .false.
        self%particle_weight = 0.
        self%norm_entropy    = 0.
        self%reject_reason   = RELIABILITY_EMPTY
        do iptcl = 1, size(self%ncand)
            do irank = 1, topk
                self%cand(irank,iptcl)%eff_weight = 0.
            end do
            nc = self%ncand(iptcl)
            if( nc < 1 ) cycle

            norm_h = 0.
            if( nc > 1 ) norm_h = self%entropy(iptcl) / log(real(nc))
            self%norm_entropy(iptcl) = norm_h

            if( nc < min_cands_eff )then
                self%reject_reason(iptcl) = RELIABILITY_TOO_FEW
                cycle
            endif
            if( norm_h > max_entropy )then
                self%reject_reason(iptcl) = RELIABILITY_HIGH_ENTROPY
                cycle
            endif

            self%accepted(iptcl)        = .true.
            self%particle_weight(iptcl) = 1.
            self%reject_reason(iptcl)   = RELIABILITY_OK
            do irank = 1, nc
                self%cand(irank,iptcl)%eff_weight = self%cand(irank,iptcl)%weight
            end do
        end do
    end subroutine evaluate_reliability

    subroutine activate_hard_fallback( self, fallback_used )
        class(joint2D_candidate_table), intent(inout) :: self
        logical, optional,              intent(out)   :: fallback_used
        integer :: iptcl, irank, nc, hard, fallback_count
        real    :: reduced_weight

        call require_allocated(self, 'hard fallback requested before build/read')
        if( present(fallback_used) ) fallback_used = .false.
        if( count(self%ncand > 0) == 0 ) return

        ! Reliability remains a soft-assignment property.  Every uncertain but
        ! otherwise valid particle still contributes through its hard winner,
        ! downweighted by the posterior winner probability.  This avoids the
        ! discontinuity where a mixed batch discarded uncertain particles while
        ! an all-uncertain batch promoted all of them to unit support.
        if( present(fallback_used) ) fallback_used = count(self%accepted) == 0

        fallback_count = 0
        do iptcl = 1, size(self%ncand)
            nc = self%ncand(iptcl)
            if( nc < 1 .or. self%accepted(iptcl) ) cycle
            hard = self%hard_rank(iptcl)
            if( hard < 1 .or. hard > nc ) cycle
            reduced_weight = self%winner_weight(iptcl)
            if( .not. finite_real(reduced_weight) .or. reduced_weight <= 0. ) cycle
            self%particle_weight(iptcl) = reduced_weight
            do irank = 1, nc
                self%cand(irank,iptcl)%eff_weight = 0.
            end do
            self%cand(hard,iptcl)%eff_weight = reduced_weight
            fallback_count = fallback_count + 1
        end do
        write(logfhandle,'(A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,L1)')&
            &'>>> JOINT2D SGD TOPK UNCERTAIN SUPPORT:', 'hard_winner=', fallback_count,&
            &'nonempty=', count(self%ncand > 0),&
            &'too_few=', count(self%reject_reason == RELIABILITY_TOO_FEW),&
            &'high_entropy=', count(self%reject_reason == RELIABILITY_HIGH_ENTROPY),&
            &'global=', count(self%accepted) == 0
    end subroutine activate_hard_fallback

    subroutine apply_reliability( self, min_cands, max_entropy, hard_fallback_when_empty )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: min_cands
        real,                           intent(in)    :: max_entropy
        logical, optional,              intent(in)    :: hard_fallback_when_empty
        logical :: l_hard_fallback_when_empty

        call self%evaluate_reliability(min_cands, max_entropy)
        l_hard_fallback_when_empty = .false.
        if( present(hard_fallback_when_empty) ) l_hard_fallback_when_empty = hard_fallback_when_empty
        if( l_hard_fallback_when_empty ) call self%activate_hard_fallback()
    end subroutine apply_reliability

    subroutine write_hard_assignments( self, assgn_map, empty_is_error )
        class(joint2D_candidate_table), intent(in)    :: self
        type(ptcl_ref),                 intent(inout) :: assgn_map(:)
        logical, optional,              intent(in)    :: empty_is_error
        logical :: l_empty_is_error
        integer :: iptcl, hard, nptcls

        call require_allocated(self, 'hard assignments requested before build/read')
        nptcls = size(self%ncand)
        if( size(assgn_map) /= nptcls ) THROW_HARD('joint2D_candidate_table: assignment map size mismatch')
        l_empty_is_error = .true.
        if( present(empty_is_error) ) l_empty_is_error = empty_is_error

        do iptcl = 1, nptcls
            if( self%ncand(iptcl) < 1 .or. self%hard_rank(iptcl) < 1 )then
                if( l_empty_is_error ) THROW_HARD('joint2D_candidate_table: empty candidate column cannot be assigned')
                cycle
            endif
            hard = self%hard_rank(iptcl)
            assgn_map(iptcl) = ptcl_ref()
            assgn_map(iptcl)%pind   = self%cand(hard,iptcl)%pind
            assgn_map(iptcl)%icls   = self%cand(hard,iptcl)%icls
            assgn_map(iptcl)%inpl   = self%cand(hard,iptcl)%inpl
            assgn_map(iptcl)%dist   = self%cand(hard,iptcl)%dist
            assgn_map(iptcl)%x      = self%cand(hard,iptcl)%x
            assgn_map(iptcl)%y      = self%cand(hard,iptcl)%y
            assgn_map(iptcl)%has_sh = self%cand(hard,iptcl)%has_sh
            assgn_map(iptcl)%frac   = 100.
            assgn_map(iptcl)%npeaks = self%ncand(iptcl)
        end do
    end subroutine write_hard_assignments

    subroutine write_table( self, fname )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: fname
        integer :: funit, io_stat, nptcls, topk

        call require_allocated(self, 'write requested before build/read')
        topk   = size(self%cand, 1)
        nptcls = size(self%cand, 2)
        open(newunit=funit, file=trim(fname), status='REPLACE', action='WRITE',&
            &access='STREAM', form='UNFORMATTED', iostat=io_stat)
        call fileiochk('joint2D_candidate_table; write_table; file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) JOINT2D_CANDIDATES_VERSION, topk, nptcls
        call fileiochk('joint2D_candidate_table; write_table(header); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%cand
        call fileiochk('joint2D_candidate_table; write_table(cand); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%shift_provenance
        call fileiochk('joint2D_candidate_table; write_table(shift provenance); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%pinds, self%ncand, self%hard_rank, self%initial_hard_rank,&
            &self%reject_reason
        call fileiochk('joint2D_candidate_table; write_table(ints); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%entropy, self%initial_entropy, self%norm_entropy, self%winner_weight
        call fileiochk('joint2D_candidate_table; write_table(reals1); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%expected_loss, self%initial_expected_loss, self%loss_delta
        call fileiochk('joint2D_candidate_table; write_table(reals2); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%particle_weight, self%base_shift, self%likelihood_scale
        call fileiochk('joint2D_candidate_table; write_table(reals3); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%accepted
        call fileiochk('joint2D_candidate_table; write_table(flags); file: '//trim(fname), io_stat)
        close(funit)
    end subroutine write_table

    subroutine read_table( self, fname )
        class(joint2D_candidate_table), intent(inout) :: self
        character(len=*),               intent(in)    :: fname
        integer :: funit, io_stat, version, topk, nptcls
        logical :: exists

        inquire(file=trim(fname), exist=exists)
        if( .not. exists ) THROW_HARD('joint2D_candidate_table: file does not exist: '//trim(fname))
        call self%kill
        open(newunit=funit, file=trim(fname), status='OLD', action='READ',&
            &access='STREAM', form='UNFORMATTED', iostat=io_stat)
        call fileiochk('joint2D_candidate_table; read_table; file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) version, topk, nptcls
        call fileiochk('joint2D_candidate_table; read_table(header); file: '//trim(fname), io_stat)
        if( version /= JOINT2D_CANDIDATES_VERSION .and. version /= 4 .and. version /= 3 .and. version /= 2 )then
            THROW_HARD('joint2D_candidate_table: unsupported file version')
        endif
        if( topk < 1 .or. nptcls < 1 )then
            THROW_HARD('joint2D_candidate_table: invalid file dimensions')
        endif
        call allocate_blank_table(self, topk, nptcls)
        read(unit=funit, iostat=io_stat) self%cand
        call fileiochk('joint2D_candidate_table; read_table(cand); file: '//trim(fname), io_stat)
        if( version >= 4 )then
            read(unit=funit, iostat=io_stat) self%shift_provenance
            call fileiochk('joint2D_candidate_table; read_table(shift provenance); file: '//trim(fname), io_stat)
        endif
        if( version >= 3 )then
            read(unit=funit, iostat=io_stat) self%pinds, self%ncand, self%hard_rank, self%initial_hard_rank,&
                &self%reject_reason
        else
            read(unit=funit, iostat=io_stat) self%ncand, self%hard_rank, self%initial_hard_rank, self%reject_reason
        endif
        call fileiochk('joint2D_candidate_table; read_table(ints); file: '//trim(fname), io_stat)
        if( version < 4 ) call infer_legacy_shift_provenance(self)
        read(unit=funit, iostat=io_stat) self%entropy, self%initial_entropy, self%norm_entropy, self%winner_weight
        call fileiochk('joint2D_candidate_table; read_table(reals1); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%expected_loss, self%initial_expected_loss, self%loss_delta
        call fileiochk('joint2D_candidate_table; read_table(reals2); file: '//trim(fname), io_stat)
        if( version >= 5 )then
            read(unit=funit, iostat=io_stat) self%particle_weight, self%base_shift, self%likelihood_scale
        else
            read(unit=funit, iostat=io_stat) self%particle_weight, self%base_shift
            self%likelihood_scale = 1.
        endif
        call fileiochk('joint2D_candidate_table; read_table(reals3); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%accepted
        call fileiochk('joint2D_candidate_table; read_table(flags); file: '//trim(fname), io_stat)
        close(funit)
        call recover_column_pinds(self)
    end subroutine read_table

    subroutine write_part_table( self, part, numlen, refined )
        class(joint2D_candidate_table), intent(in) :: self
        integer,                        intent(in) :: part
        integer,                        intent(in) :: numlen
        logical, optional,              intent(in) :: refined
        if( present(refined) )then
            call self%write_table(joint2D_candidate_part_fname(part, numlen, refined))
        else
            call self%write_table(joint2D_candidate_part_fname(part, numlen))
        endif
    end subroutine write_part_table

    subroutine read_part_table( self, part, numlen, refined )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: part
        integer,                        intent(in)    :: numlen
        logical, optional,              intent(in)    :: refined
        if( present(refined) )then
            call self%read_table(joint2D_candidate_part_fname(part, numlen, refined))
        else
            call self%read_table(joint2D_candidate_part_fname(part, numlen))
        endif
    end subroutine read_part_table

    subroutine extract_by_pinds( self, pinds, part )
        class(joint2D_candidate_table), intent(in)    :: self
        integer,                        intent(in)    :: pinds(:)
        type(joint2D_candidate_table),  intent(inout) :: part
        integer :: iptcl, src_col, topk

        call require_allocated(self, 'partition extract requested before build/read')
        if( size(pinds) < 1 ) THROW_HARD('joint2D_candidate_table: cannot extract empty particle list')
        topk = size(self%cand, 1)
        call allocate_blank_table(part, topk, size(pinds))
        part%pinds = pinds
        do iptcl = 1, size(pinds)
            src_col = find_pind_column(self, pinds(iptcl))
            if( src_col < 1 )then
                THROW_HARD('joint2D_candidate_table: partition particle not found: '//int2str(pinds(iptcl)))
            endif
            call copy_candidate_column(self, src_col, part, iptcl)
        end do
    end subroutine extract_by_pinds

    subroutine merge_parts_by_pinds( self, parts, pinds )
        class(joint2D_candidate_table), intent(inout) :: self
        type(joint2D_candidate_table),  intent(in)    :: parts(:)
        integer,                        intent(in)    :: pinds(:)
        integer :: ipart, iptcl, src_col, topk
        logical :: found

        if( size(parts) < 1 ) THROW_HARD('joint2D_candidate_table: no parts to merge')
        if( size(pinds) < 1 ) THROW_HARD('joint2D_candidate_table: cannot merge empty particle list')
        call require_allocated(parts(1), 'partition merge part is not allocated')
        topk = size(parts(1)%cand, 1)
        do ipart = 2, size(parts)
            call require_allocated(parts(ipart), 'partition merge part is not allocated')
            if( size(parts(ipart)%cand, 1) /= topk )then
                THROW_HARD('joint2D_candidate_table: partition top-K mismatch during merge')
            endif
        end do
        call allocate_blank_table(self, topk, size(pinds))
        self%pinds = pinds
        do iptcl = 1, size(pinds)
            found = .false.
            do ipart = 1, size(parts)
                src_col = find_pind_column(parts(ipart), pinds(iptcl))
                if( src_col > 0 )then
                    call copy_candidate_column(parts(ipart), src_col, self, iptcl)
                    found = .true.
                    exit
                endif
            end do
            if( .not. found )then
                THROW_HARD('joint2D_candidate_table: merged particle not found: '//int2str(pinds(iptcl)))
            endif
        end do
    end subroutine merge_parts_by_pinds

    logical function records_equal( self, other, tol ) result( equal )
        class(joint2D_candidate_table), intent(in) :: self
        type(joint2D_candidate_table),  intent(in) :: other
        real, optional,                 intent(in) :: tol
        real :: rt
        integer :: iptcl, irank

        rt = 0.
        if( present(tol) ) rt = tol
        equal = .false.
        if( .not. allocated(self%ncand) .or. .not. allocated(other%ncand) ) return
        if( any(shape(self%cand) /= shape(other%cand)) ) return
        if( size(self%ncand) /= size(other%ncand) ) return
        if( any(self%pinds /= other%pinds) ) return
        if( any(self%ncand /= other%ncand) ) return
        if( any(self%hard_rank /= other%hard_rank) ) return
        if( any(self%initial_hard_rank /= other%initial_hard_rank) ) return
        if( any(self%reject_reason /= other%reject_reason) ) return
        if( any(.not. (self%accepted .eqv. other%accepted)) ) return
        if( any(abs(self%entropy - other%entropy) > rt) ) return
        if( any(abs(self%initial_entropy - other%initial_entropy) > rt) ) return
        if( any(abs(self%norm_entropy - other%norm_entropy) > rt) ) return
        if( any(abs(self%winner_weight - other%winner_weight) > rt) ) return
        if( any(abs(self%expected_loss - other%expected_loss) > rt) ) return
        if( any(abs(self%initial_expected_loss - other%initial_expected_loss) > rt) ) return
        if( any(abs(self%loss_delta - other%loss_delta) > rt) ) return
        if( any(abs(self%particle_weight - other%particle_weight) > rt) ) return
        if( any(abs(self%base_shift - other%base_shift) > rt) ) return
        if( any(abs(self%likelihood_scale - other%likelihood_scale) > rt) ) return
        if( any(self%shift_provenance /= other%shift_provenance) ) return
        do iptcl = 1, size(self%ncand)
            do irank = 1, size(self%cand, 1)
                if( .not. candidates_equal(self%cand(irank,iptcl), other%cand(irank,iptcl), rt) ) return
            end do
        end do
        equal = .true.
    end function records_equal

    subroutine export_batch( self, first_ptcl, last_ptcl, refs, weights, ncands )
        class(joint2D_candidate_table), intent(in)  :: self
        integer,                        intent(in)  :: first_ptcl, last_ptcl
        type(ptcl_ref), allocatable,    intent(out) :: refs(:,:)
        real,           allocatable,    intent(out) :: weights(:,:)
        integer,        allocatable,    intent(out) :: ncands(:)
        integer :: batchsz, iloc, iptcl, irank, nc, topk

        call require_allocated(self, 'batch export requested before build/read')
        if( first_ptcl < 1 .or. last_ptcl < first_ptcl .or. last_ptcl > size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: invalid batch export range')
        endif

        topk    = size(self%cand, 1)
        batchsz = last_ptcl - first_ptcl + 1
        allocate(refs(topk,batchsz), weights(topk,batchsz), ncands(batchsz))
        refs    = ptcl_ref()
        weights = 0.
        ncands  = 0

        do iloc = 1, batchsz
            iptcl = first_ptcl + iloc - 1
            nc = self%ncand(iptcl)
            ncands(iloc) = nc
            if( nc < 1 .or. self%particle_weight(iptcl) <= 0. ) cycle
            do irank = 1, nc
                refs(irank,iloc) = ref_from_candidate(self, irank, iptcl)
                weights(irank,iloc) = self%cand(irank,iptcl)%eff_weight
            end do
        end do
    end subroutine export_batch

    subroutine write_diag( self, label, iteration )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: label
        integer, optional,               intent(in) :: iteration
        integer :: nptcls, topk, nonempty, empty_count, accepted_count, too_few_count, entropy_count
        integer :: fallback_count, soft_accepted_count, contributing_count, winner_churn_count, diag_iteration
        integer :: iptcl, irank, nc, gap21_count, gap31_count, logit_range_count
        integer :: rank_weight_count, softmax_nonfinite
        real    :: avg_ncand, avg_entropy, avg_initial_entropy, avg_norm_entropy, avg_winner_weight
        real    :: avg_initial_loss, avg_expected_loss, avg_loss_delta
        real    :: accepted_fraction, entropy_min, entropy_max, norm_entropy_min, norm_entropy_max
        real    :: winner_weight_min, winner_weight_max, fallback_fraction, effective_support
        real    :: dist1, dist2, dist3, cand_dist, logit_min, logit_max, weight_sum, rank_weight_mean
        real    :: gap21_q(3), gap31_q(3), logit_range_q(3), norm_entropy_q(3), winner_weight_q(3)
        real    :: weight_sum_q(3), rank_weight_q(3), particle_weight_q(3)
        logical :: global_fallback
        real, allocatable :: gap21_vals(:), gap31_vals(:), logit_range_vals(:)
        real, allocatable :: weight_sum_vals(:), rank_weight_vals(:)

        if( .not. allocated(self%ncand) )then
            write(logfhandle,'(A,1X,A)') '>>> JOINT2D SGD TOPK:', trim(label)//' table not allocated'
            return
        endif
        nptcls         = size(self%ncand)
        topk           = size(self%cand, 1)
        nonempty       = count(self%ncand > 0)
        empty_count    = nptcls - nonempty
        accepted_count = count(self%accepted)
        too_few_count  = count(self%reject_reason == RELIABILITY_TOO_FEW)
        entropy_count  = count(self%reject_reason == RELIABILITY_HIGH_ENTROPY)
        fallback_count = count((self%particle_weight > 0.) .and. self%reject_reason /= RELIABILITY_OK)
        soft_accepted_count = count(self%accepted .and. self%reject_reason == RELIABILITY_OK)
        contributing_count = count(self%particle_weight > 0.)
        effective_support = sum(self%particle_weight)
        global_fallback = nonempty > 0 .and. soft_accepted_count == 0 .and. fallback_count > 0
        winner_churn_count = count((self%ncand > 0) .and. (self%initial_hard_rank /= self%hard_rank))
        diag_iteration = -1
        if( present(iteration) ) diag_iteration = iteration
        avg_ncand = 0.
        avg_entropy = 0.
        avg_initial_entropy = 0.
        avg_norm_entropy = 0.
        avg_winner_weight = 0.
        avg_initial_loss = 0.
        avg_expected_loss = 0.
        avg_loss_delta = 0.
        accepted_fraction = 0.
        entropy_min = 0.
        entropy_max = 0.
        norm_entropy_min = 0.
        norm_entropy_max = 0.
        winner_weight_min = 0.
        winner_weight_max = 0.
        fallback_fraction = 0.
        gap21_q = 0.
        gap31_q = 0.
        logit_range_q = 0.
        norm_entropy_q = 0.
        winner_weight_q = 0.
        weight_sum_q = 0.
        rank_weight_q = 0.
        particle_weight_q = 0.
        gap21_count = 0
        gap31_count = 0
        logit_range_count = 0
        softmax_nonfinite = 0
        allocate(gap21_vals(nptcls), gap31_vals(nptcls), logit_range_vals(nptcls),&
            &weight_sum_vals(nptcls), rank_weight_vals(nptcls), source=0.)
        if( nptcls > 0 ) avg_ncand = real(sum(self%ncand)) / real(nptcls)
        if( nptcls > 0 ) accepted_fraction = real(accepted_count) / real(nptcls)
        if( nonempty > 0 ) fallback_fraction = real(fallback_count) / real(nonempty)
        if( nonempty > 0 )then
            avg_entropy       = sum(self%entropy,       mask=self%ncand > 0) / real(nonempty)
            avg_initial_entropy = sum(self%initial_entropy, mask=self%ncand > 0) / real(nonempty)
            avg_norm_entropy  = sum(self%norm_entropy,  mask=self%ncand > 0) / real(nonempty)
            avg_winner_weight = sum(self%winner_weight, mask=self%ncand > 0) / real(nonempty)
            avg_initial_loss  = sum(self%initial_expected_loss, mask=self%ncand > 0) / real(nonempty)
            avg_expected_loss = sum(self%expected_loss, mask=self%ncand > 0) / real(nonempty)
            avg_loss_delta    = sum(self%loss_delta, mask=self%ncand > 0) / real(nonempty)
            entropy_min       = minval(self%entropy,       mask=self%ncand > 0)
            entropy_max       = maxval(self%entropy,       mask=self%ncand > 0)
            norm_entropy_min  = minval(self%norm_entropy,  mask=self%ncand > 0)
            norm_entropy_max  = maxval(self%norm_entropy,  mask=self%ncand > 0)
            winner_weight_min = minval(self%winner_weight, mask=self%ncand > 0)
            winner_weight_max = maxval(self%winner_weight, mask=self%ncand > 0)
        endif
        do iptcl = 1, nptcls
            nc = self%ncand(iptcl)
            if( nc < 1 ) cycle
            dist1 = huge(1.0)
            dist2 = huge(1.0)
            dist3 = huge(1.0)
            logit_min = huge(1.0)
            logit_max = -huge(1.0)
            weight_sum = 0.
            do irank = 1, nc
                cand_dist = self%cand(irank,iptcl)%dist
                if( cand_dist < dist1 )then
                    dist3 = dist2
                    dist2 = dist1
                    dist1 = cand_dist
                else if( cand_dist < dist2 )then
                    dist3 = dist2
                    dist2 = cand_dist
                else if( cand_dist < dist3 )then
                    dist3 = cand_dist
                endif
                logit_min = min(logit_min, self%cand(irank,iptcl)%logit)
                logit_max = max(logit_max, self%cand(irank,iptcl)%logit)
                weight_sum = weight_sum + self%cand(irank,iptcl)%weight
                if( .not. finite_real(self%cand(irank,iptcl)%weight) )&
                    &softmax_nonfinite = softmax_nonfinite + 1
            end do
            logit_range_count = logit_range_count + 1
            logit_range_vals(logit_range_count) = logit_max - logit_min
            weight_sum_vals(logit_range_count) = weight_sum
            if( .not. finite_real(weight_sum) ) softmax_nonfinite = softmax_nonfinite + 1
            if( nc >= 2 )then
                gap21_count = gap21_count + 1
                gap21_vals(gap21_count) = dist2 - dist1
            endif
            if( nc >= 3 )then
                gap31_count = gap31_count + 1
                gap31_vals(gap31_count) = dist3 - dist1
            endif
        end do
        call diagnostic_quantiles(gap21_vals, gap21_count, gap21_q)
        call diagnostic_quantiles(gap31_vals, gap31_count, gap31_q)
        call diagnostic_quantiles(logit_range_vals, logit_range_count, logit_range_q)
        call diagnostic_quantiles(pack(self%norm_entropy, self%ncand > 0), nonempty, norm_entropy_q)
        call diagnostic_quantiles(pack(self%winner_weight, self%ncand > 0), nonempty, winner_weight_q)
        call diagnostic_quantiles(weight_sum_vals, logit_range_count, weight_sum_q)
        call diagnostic_quantiles(pack(self%particle_weight, self%particle_weight > 0.),&
            &contributing_count, particle_weight_q)
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
            &'>>> JOINT2D SGD TOPK:', trim(label), 'topk=', topk, 'nptcls=', nptcls, 'empty=', empty_count,&
            &'accepted=', accepted_count, 'too_few=', too_few_count, 'high_entropy=', entropy_count,&
            &'fallback=', fallback_count
        write(logfhandle,'(A,1X,A,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3,1X,A,I0)')&
            &'>>> JOINT2D SGD TOPK STATS:', trim(label), 'avg_ncand=', avg_ncand,&
            &'avg_entropy=', avg_entropy, 'avg_norm_entropy=', avg_norm_entropy,&
            &'avg_winner_weight=', avg_winner_weight, 'winner_churn=', winner_churn_count
        write(logfhandle,'(A,1X,A,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4,1X,A,F7.3)')&
            &'>>> JOINT2D SGD LATENT:', trim(label), 'avg_initial_loss=', avg_initial_loss,&
            &'avg_final_loss=', avg_expected_loss, 'avg_loss_delta=', avg_loss_delta,&
            &'avg_initial_entropy=', avg_initial_entropy
        write(logfhandle,'(A,1X,A,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3)')&
            &'>>> JOINT2D SGD TOPK RANGES:', trim(label), 'accepted_frac=', accepted_fraction,&
            &'entropy_min=', entropy_min, 'entropy_max=', entropy_max,&
            &'norm_entropy_min=', norm_entropy_min, 'norm_entropy_max=', norm_entropy_max
        write(logfhandle,'(A,1X,A,1X,A,F7.3,1X,A,F7.3)')&
            &'>>> JOINT2D SGD WINNER:', trim(label), 'weight_min=', winner_weight_min,&
            &'weight_max=', winner_weight_max
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,F8.5,1X,A,L1)')&
            &'>>> JOINT2D SGD RELIABILITY:', trim(label), 'iteration=', diag_iteration,&
            &'soft_accepted=', soft_accepted_count, 'accepted=', accepted_count,&
            &'eligible=', nonempty, 'contributing=', contributing_count, 'fallback=', fallback_count,&
            &'fallback_frac=', fallback_fraction, 'global_fallback=', global_fallback
        write(logfhandle,'(A,1X,A,1X,A,ES12.4,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5)')&
            &'>>> JOINT2D SGD PARTICLE SUPPORT:', trim(label), 'effective=', effective_support,&
            &'p10=', particle_weight_q(1), 'p50=', particle_weight_q(2), 'p90=', particle_weight_q(3)
        write(logfhandle,'(A,1X,A,1X,A,A,1X,A,I0,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4)')&
            &'>>> JOINT2D SGD DIST GAP QUANTILES:', trim(label), 'gap=', 'd2-d1', 'samples=', gap21_count,&
            &'p10=', gap21_q(1), 'p50=', gap21_q(2), 'p90=', gap21_q(3)
        write(logfhandle,'(A,1X,A,1X,A,A,1X,A,I0,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4)')&
            &'>>> JOINT2D SGD DIST GAP QUANTILES:', trim(label), 'gap=', 'd3-d1', 'samples=', gap31_count,&
            &'p10=', gap31_q(1), 'p50=', gap31_q(2), 'p90=', gap31_q(3)
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4)')&
            &'>>> JOINT2D SGD LOGIT RANGE QUANTILES:', trim(label), 'samples=', logit_range_count,&
            &'p10=', logit_range_q(1), 'p50=', logit_range_q(2), 'p90=', logit_range_q(3)
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5)')&
            &'>>> JOINT2D SGD ENTROPY QUANTILES:', trim(label), 'samples=', nonempty,&
            &'norm_p10=', norm_entropy_q(1), 'norm_p50=', norm_entropy_q(2), 'norm_p90=', norm_entropy_q(3),&
            &'winner_p10=', winner_weight_q(1), 'winner_p50=', winner_weight_q(2), 'winner_p90=', winner_weight_q(3)
        write(logfhandle,'(A,1X,A,1X,A,A,1X,A,A,1X,A,I0,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5,1X,A,I0)')&
            &'>>> JOINT2D SGD SOFTMAX:', trim(label), 'transform=', 'exp(logit-max)/sum',&
            &'logit_source=', 'negative_distance_plus_updates', 'samples=', logit_range_count,&
            &'weight_sum_p10=', weight_sum_q(1), 'weight_sum_p50=', weight_sum_q(2),&
            &'weight_sum_p90=', weight_sum_q(3), 'nonfinite=', softmax_nonfinite
        do irank = 1, topk
            rank_weight_count = 0
            rank_weight_mean  = 0.
            rank_weight_q     = 0.
            do iptcl = 1, nptcls
                if( self%ncand(iptcl) < irank ) cycle
                rank_weight_count = rank_weight_count + 1
                rank_weight_vals(rank_weight_count) = self%cand(irank,iptcl)%weight
                rank_weight_mean = rank_weight_mean + self%cand(irank,iptcl)%weight
            end do
            if( rank_weight_count > 0 ) rank_weight_mean = rank_weight_mean / real(rank_weight_count)
            call diagnostic_quantiles(rank_weight_vals, rank_weight_count, rank_weight_q)
            write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5,1X,A,F8.5)')&
                &'>>> JOINT2D SGD WEIGHTS:', trim(label), 'rank=', irank, 'samples=', rank_weight_count,&
                &'mean=', rank_weight_mean, 'p10=', rank_weight_q(1), 'p50=', rank_weight_q(2),&
                &'p90=', rank_weight_q(3)
        end do
        deallocate(gap21_vals, gap31_vals, logit_range_vals, weight_sum_vals, rank_weight_vals)
    end subroutine write_diag

    subroutine diagnostic_quantiles( vals, nvals, quantiles )
        real,              intent(in)  :: vals(:)
        integer,           intent(in)  :: nvals
        real,              intent(out) :: quantiles(3)
        real, allocatable :: sorted(:)
        integer :: idx10, idx50, idx90

        quantiles = 0.
        if( nvals < 1 ) return
        if( nvals > size(vals) ) THROW_HARD('joint2D_candidate_table: diagnostic quantile size mismatch')
        allocate(sorted(nvals), source=vals(1:nvals))
        call hpsort(sorted)
        idx10 = 1 + int(0.10 * real(nvals - 1))
        idx50 = 1 + int(0.50 * real(nvals - 1))
        idx90 = 1 + int(0.90 * real(nvals - 1))
        quantiles = [sorted(idx10), sorted(idx50), sorted(idx90)]
        deallocate(sorted)
    end subroutine diagnostic_quantiles

    subroutine write_balance_diag( self, label, diag )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: label
        type(joint2D_balance_diag),     intent(in) :: diag

        if( .not. allocated(self%ncand) )then
            write(logfhandle,'(A,1X,A)') '>>> JOINT2D SGD BALANCE:', trim(label)//' table not allocated'
            return
        endif
        write(logfhandle,'(A,1X,A,1X,A,ES12.4,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
            &'>>> JOINT2D SGD BALANCE:', trim(label), 'weight=', diag%balance_weight,&
            &'eligible=', diag%eligible_particles, 'empty=', diag%empty_particles,&
            &'candidates=', diag%candidates, 'winner_churn=', diag%winner_churn
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4)')&
            &'>>> JOINT2D SGD BALANCE SUPPORT:', trim(label), 'active_classes=', diag%active_classes,&
            &'zero_support_classes=', diag%zero_support_classes, 'support_min=', diag%support_min,&
            &'support_mean=', diag%support_mean, 'support_max=', diag%support_max
        write(logfhandle,'(A,1X,A,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4,1X,A,I0)')&
            &'>>> JOINT2D SGD BALANCE PRIOR:', trim(label), 'prior_min=', diag%prior_min,&
            &'prior_max=', diag%prior_max, 'entropy_before=', diag%entropy_before,&
            &'entropy_after=', diag%entropy_after, 'nonfinite=', diag%nonfinite
    end subroutine write_balance_diag

    integer function candidate_table_checksum( self ) result( chksum )
        class(joint2D_candidate_table), intent(in) :: self
        integer(kind=8) :: h
        integer :: iptcl, irank

        call require_allocated(self, 'checksum requested before build/read')
        h = 146959810_8
        call mix_int64(h, size(self%cand, 1))
        call mix_int64(h, size(self%cand, 2))
        do iptcl = 1, size(self%ncand)
            call mix_int64(h, self%pinds(iptcl))
            call mix_int64(h, self%ncand(iptcl))
            call mix_int64(h, self%hard_rank(iptcl))
            call mix_int64(h, self%initial_hard_rank(iptcl))
            call mix_int64(h, self%reject_reason(iptcl))
            call mix_real64(h, self%entropy(iptcl))
            call mix_real64(h, self%norm_entropy(iptcl))
            call mix_real64(h, self%winner_weight(iptcl))
            call mix_real64(h, self%expected_loss(iptcl))
            call mix_real64(h, self%loss_delta(iptcl))
            call mix_real64(h, self%particle_weight(iptcl))
            call mix_real64(h, self%base_shift(1,iptcl))
            call mix_real64(h, self%base_shift(2,iptcl))
            call mix_real64(h, self%likelihood_scale(iptcl))
            if( self%accepted(iptcl) )then
                call mix_int64(h, 1)
            else
                call mix_int64(h, 0)
            endif
            do irank = 1, size(self%cand, 1)
                call mix_candidate(h, self%cand(irank,iptcl))
                call mix_int64(h, self%shift_provenance(irank,iptcl))
            end do
        end do
        chksum = int(modulo(h, 2147483647_8))
    end function candidate_table_checksum

    subroutine write_distributed_diag( self, label, part, nparts )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: label
        integer, optional,              intent(in) :: part
        integer, optional,              intent(in) :: nparts
        integer :: ipart, nparts_eff, nptcls, accepted_count, contributing_count, cand_count
        real    :: support_sum

        if( .not. allocated(self%ncand) )then
            write(logfhandle,'(A,1X,A)') '>>> JOINT2D SGD DISTR:', trim(label)//' table not allocated'
            return
        endif
        ipart = 0
        nparts_eff = 0
        if( present(part) ) ipart = part
        if( present(nparts) ) nparts_eff = nparts
        nptcls = size(self%ncand)
        accepted_count = count(self%accepted)
        contributing_count = count(self%particle_weight > 0.)
        cand_count = sum(self%ncand)
        support_sum = 0.
        if( nptcls > 0 ) support_sum = sum(self%particle_weight)
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
            &'>>> JOINT2D SGD DISTR:', trim(label), 'part=', ipart, 'nparts=', nparts_eff,&
            &'nptcls=', nptcls, 'topk=', size(self%cand, 1)
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,ES12.4,1X,A,I0)')&
            &'>>> JOINT2D SGD DISTR PARTS:', trim(label), 'accepted=', accepted_count,&
            &'contributing=', contributing_count, 'candidates=', cand_count,&
            &'checksum=', self%checksum(), 'support=', support_sum,&
            &'nonfinite=', count_nonfinite_records(self)
    end subroutine write_distributed_diag

    subroutine write_shift_provenance_diag( self, label )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: label
        integer :: class_refined, materialized_seed, genuine_zero, invalid, iptcl, irank
        integer :: missing_shift, nonfinite_delta, nonfinite_base

        call require_allocated(self, 'shift-provenance diagnostics requested before build/read')
        class_refined      = 0
        materialized_seed = 0
        genuine_zero      = 0
        invalid           = 0
        missing_shift     = 0
        nonfinite_delta   = 0
        nonfinite_base    = 0
        do iptcl = 1, size(self%ncand)
            if( .not. finite_real(self%base_shift(1,iptcl)) .or.&
                &.not. finite_real(self%base_shift(2,iptcl)) ) nonfinite_base = nonfinite_base + 1
            do irank = 1, self%ncand(iptcl)
                select case(self%shift_provenance(irank,iptcl))
                case(SHIFT_PROVENANCE_CLASS_REFINED)
                    class_refined = class_refined + 1
                case(SHIFT_PROVENANCE_SEED)
                    materialized_seed = materialized_seed + 1
                case(SHIFT_PROVENANCE_ZERO)
                    genuine_zero = genuine_zero + 1
                case default
                    invalid = invalid + 1
                end select
                if( self%shift_provenance(irank,iptcl) /= SHIFT_PROVENANCE_ZERO .and.&
                    &.not. self%cand(irank,iptcl)%has_sh ) missing_shift = missing_shift + 1
                if( .not. finite_real(self%cand(irank,iptcl)%x) .or.&
                    &.not. finite_real(self%cand(irank,iptcl)%y) ) nonfinite_delta = nonfinite_delta + 1
            enddo
        enddo
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
            &'>>> JOINT2D SGD SHIFT PROVENANCE:', trim(label), 'class_refined=', class_refined,&
            &'materialized_seed=', materialized_seed, 'genuine_zero=', genuine_zero, 'invalid=', invalid,&
            &'missing_shift=', missing_shift, 'nonfinite_delta=', nonfinite_delta, 'nonfinite_base=', nonfinite_base
        write(logfhandle,'(A)')&
            &'>>> JOINT2D SGD SHIFT CONVENTION: candidate_shift=delta scoring_shift=rotate(delta) assignment_shift=base_plus_delta'
        if( invalid > 0 .or. missing_shift > 0 .or. nonfinite_delta > 0 .or. nonfinite_base > 0 )then
            THROW_HARD('joint2D candidate shift provenance/convention invariant failed')
        endif
    end subroutine write_shift_provenance_diag

    subroutine kill_candidate_table( self )
        class(joint2D_candidate_table), intent(inout) :: self
        if( allocated(self%cand)            ) deallocate(self%cand)
        if( allocated(self%pinds)           ) deallocate(self%pinds)
        if( allocated(self%ncand)           ) deallocate(self%ncand)
        if( allocated(self%hard_rank)       ) deallocate(self%hard_rank)
        if( allocated(self%initial_hard_rank) ) deallocate(self%initial_hard_rank)
        if( allocated(self%reject_reason)   ) deallocate(self%reject_reason)
        if( allocated(self%entropy)         ) deallocate(self%entropy)
        if( allocated(self%initial_entropy) ) deallocate(self%initial_entropy)
        if( allocated(self%norm_entropy)    ) deallocate(self%norm_entropy)
        if( allocated(self%winner_weight)   ) deallocate(self%winner_weight)
        if( allocated(self%expected_loss)   ) deallocate(self%expected_loss)
        if( allocated(self%initial_expected_loss) ) deallocate(self%initial_expected_loss)
        if( allocated(self%loss_delta)      ) deallocate(self%loss_delta)
        if( allocated(self%particle_weight) ) deallocate(self%particle_weight)
        if( allocated(self%base_shift)      ) deallocate(self%base_shift)
        if( allocated(self%likelihood_scale)) deallocate(self%likelihood_scale)
        if( allocated(self%shift_provenance)) deallocate(self%shift_provenance)
        if( allocated(self%accepted)        ) deallocate(self%accepted)
    end subroutine kill_candidate_table

    subroutine infer_legacy_shift_provenance( self )
        class(joint2D_candidate_table), intent(inout) :: self
        integer :: iptcl, irank

        self%shift_provenance = SHIFT_PROVENANCE_INVALID
        do iptcl = 1, size(self%ncand)
            do irank = 1, self%ncand(iptcl)
                if( self%cand(irank,iptcl)%has_sh )then
                    self%shift_provenance(irank,iptcl) = SHIFT_PROVENANCE_CLASS_REFINED
                else
                    self%shift_provenance(irank,iptcl) = SHIFT_PROVENANCE_ZERO
                endif
            enddo
        enddo
    end subroutine infer_legacy_shift_provenance

    logical function valid_ref( ref ) result( is_valid )
        type(ptcl_ref), intent(in) :: ref
        is_valid = ref%pind > 0 .and. ref%icls > 0 .and. ref%inpl > 0
        if( is_valid )then
            is_valid = finite_real(ref%dist)
        endif
    end function valid_ref

    logical function finite_real( val ) result( is_finite )
        real, intent(in) :: val
        is_finite = (val == val) .and. (abs(val) < huge(val) / 2.0)
    end function finite_real

    real function refinement_tolerance( old_dist, new_dist ) result( tol )
        real, intent(in) :: old_dist, new_dist
        tol = 128. * epsilon(1.0) * max(1.0, abs(old_dist), abs(new_dist))
    end function refinement_tolerance

    subroutine insert_candidate( self, iptcl, topk, ref )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        integer,                        intent(in)    :: topk
        type(ptcl_ref),                 intent(in)    :: ref
        type(joint2D_candidate) :: newcand
        integer :: pos, j, nnew

        newcand = candidate_from_ref(ref)
        pos = self%ncand(iptcl) + 1
        do j = 1, self%ncand(iptcl)
            if( candidate_less(newcand, self%cand(j,iptcl)) )then
                pos = j
                exit
            endif
        end do
        if( pos > topk ) return
        nnew = min(topk, self%ncand(iptcl) + 1)
        do j = nnew, pos + 1, -1
            self%cand(j,iptcl) = self%cand(j-1,iptcl)
            self%shift_provenance(j,iptcl) = self%shift_provenance(j-1,iptcl)
        end do
        self%cand(pos,iptcl) = newcand
        self%shift_provenance(pos,iptcl) = merge(SHIFT_PROVENANCE_CLASS_REFINED,&
            &SHIFT_PROVENANCE_ZERO, newcand%has_sh)
        self%ncand(iptcl) = nnew
    end subroutine insert_candidate

    type(joint2D_candidate) function candidate_from_ref( ref ) result( cand )
        type(ptcl_ref), intent(in) :: ref
        cand%pind   = ref%pind
        cand%icls   = ref%icls
        cand%inpl   = ref%inpl
        cand%dist   = ref%dist
        cand%x      = ref%x
        cand%y      = ref%y
        cand%has_sh = ref%has_sh
    end function candidate_from_ref

    logical function candidate_less( lhs, rhs ) result( less )
        type(joint2D_candidate), intent(in) :: lhs, rhs
        less = .false.
        if( lhs%dist < rhs%dist )then
            less = .true.
        else if( lhs%dist == rhs%dist )then
            if( lhs%icls < rhs%icls )then
                less = .true.
            else if( lhs%icls == rhs%icls .and. lhs%inpl < rhs%inpl )then
                less = .true.
            endif
        endif
    end function candidate_less

    subroutine finalize_particle( self, iptcl )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        integer :: irank, nc

        nc = self%ncand(iptcl)
        if( nc < 1 ) return

        do irank = 1, nc
            ! The joint 2D matcher supplies calibrated Gaussian negative log-likelihoods.
            self%cand(irank,iptcl)%logit = -self%cand(irank,iptcl)%dist
        end do
        call refresh_particle(self, iptcl)
        self%initial_hard_rank(iptcl)     = self%hard_rank(iptcl)
        self%initial_entropy(iptcl)       = self%entropy(iptcl)
        self%initial_expected_loss(iptcl) = self%expected_loss(iptcl)
        self%loss_delta(iptcl)            = 0.
    end subroutine finalize_particle

    subroutine optimize_particle_logits( self, iptcl, eta_latent )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        real,                           intent(in)    :: eta_latent
        integer :: irank, nc
        real    :: grad, loss

        nc = self%ncand(iptcl)
        if( nc < 1 ) return
        loss = self%expected_loss(iptcl)
        do irank = 1, nc
            grad = self%cand(irank,iptcl)%weight * (self%cand(irank,iptcl)%dist - loss)
            self%cand(irank,iptcl)%logit = self%cand(irank,iptcl)%logit - eta_latent * grad
        end do
    end subroutine optimize_particle_logits

    subroutine refresh_particle( self, iptcl )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        integer :: irank, nc
        real    :: max_score, denom, score, w, best_weight

        nc = self%ncand(iptcl)
        self%hard_rank(iptcl)     = 0
        self%entropy(iptcl)       = 0.
        self%norm_entropy(iptcl)  = 0.
        self%winner_weight(iptcl) = 0.
        self%expected_loss(iptcl) = 0.
        do irank = 1, size(self%cand, 1)
            self%cand(irank,iptcl)%hard       = .false.
            self%cand(irank,iptcl)%weight     = 0.
            self%cand(irank,iptcl)%eff_weight = 0.
        end do
        if( nc < 1 ) return

        max_score = -huge(1.0)
        do irank = 1, nc
            self%cand(irank,iptcl)%rank = irank
            score = self%cand(irank,iptcl)%logit
            max_score = max(max_score, score)
        end do

        denom = 0.
        do irank = 1, nc
            score = self%cand(irank,iptcl)%logit
            denom = denom + exp(score - max_score)
        end do
        if( denom <= 0. .or. denom /= denom )then
            self%cand(1,iptcl)%weight     = 1.
            self%cand(1,iptcl)%eff_weight = 1.
            self%hard_rank(iptcl)         = 1
            self%winner_weight(iptcl)     = 1.
            self%expected_loss(iptcl)     = self%cand(1,iptcl)%dist
            self%cand(1,iptcl)%hard       = .true.
            return
        endif

        best_weight = -1.
        self%hard_rank(iptcl) = 1
        do irank = 1, nc
            score = self%cand(irank,iptcl)%logit
            w = exp(score - max_score) / denom
            self%cand(irank,iptcl)%weight = w
            self%cand(irank,iptcl)%eff_weight = w
            self%expected_loss(iptcl) = self%expected_loss(iptcl) + w * self%cand(irank,iptcl)%dist
            if( w > 0. ) self%entropy(iptcl) = self%entropy(iptcl) - w * log(w)
            if( w > best_weight )then
                best_weight = w
                self%hard_rank(iptcl) = irank
            endif
        end do
        self%winner_weight(iptcl) = self%cand(self%hard_rank(iptcl),iptcl)%weight
        self%cand(self%hard_rank(iptcl),iptcl)%hard = .true.
        if( nc > 1 ) self%norm_entropy(iptcl) = self%entropy(iptcl) / log(real(nc))
    end subroutine refresh_particle

    type(ptcl_ref) function ref_from_candidate( self, irank, iptcl ) result( ref )
        class(joint2D_candidate_table), intent(in) :: self
        integer,                        intent(in) :: irank, iptcl
        real :: x_delta, y_delta

        ref = ptcl_ref()
        ref%pind   = self%cand(irank,iptcl)%pind
        ref%icls   = self%cand(irank,iptcl)%icls
        ref%inpl   = self%cand(irank,iptcl)%inpl
        ref%dist   = self%cand(irank,iptcl)%dist
        ref%frac   = 100.
        ref%npeaks = self%ncand(iptcl)
        x_delta = 0.
        y_delta = 0.
        if( self%cand(irank,iptcl)%has_sh )then
            x_delta = self%cand(irank,iptcl)%x
            y_delta = self%cand(irank,iptcl)%y
        endif
        ref%x = self%base_shift(1,iptcl) + x_delta
        ref%y = self%base_shift(2,iptcl) + y_delta
        ref%has_sh = .true.
    end function ref_from_candidate

    subroutine require_allocated( self, msg )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: msg
        if( .not. allocated(self%cand) .or. .not. allocated(self%ncand) .or.&
            &.not. allocated(self%accepted) )then
            THROW_HARD('joint2D_candidate_table: '//trim(msg))
        endif
    end subroutine require_allocated

    subroutine require_finite_particle( self, iptcl, msg )
        class(joint2D_candidate_table), intent(in) :: self
        integer,                        intent(in) :: iptcl
        character(len=*),               intent(in) :: msg
        integer :: irank, nc

        if( iptcl < 1 .or. iptcl > size(self%ncand) )then
            THROW_HARD('joint2D_candidate_table: finite check particle index out of range')
        endif
        if( .not. finite_real(self%entropy(iptcl)) .or. .not. finite_real(self%winner_weight(iptcl)) .or.&
            &.not. finite_real(self%expected_loss(iptcl)) )then
            THROW_HARD('joint2D_candidate_table: nonfinite '//trim(msg)//' particle diagnostic')
        endif
        nc = self%ncand(iptcl)
        do irank = 1, nc
            if( .not. finite_real(self%cand(irank,iptcl)%dist) .or.&
                &.not. finite_real(self%cand(irank,iptcl)%logit) .or.&
                &.not. finite_real(self%cand(irank,iptcl)%weight) .or.&
                &.not. finite_real(self%cand(irank,iptcl)%eff_weight) )then
                THROW_HARD('joint2D_candidate_table: nonfinite '//trim(msg)//' candidate diagnostic')
            endif
        end do
    end subroutine require_finite_particle

    subroutine allocate_blank_table( self, topk, nptcls )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: topk
        integer,                        intent(in)    :: nptcls

        if( topk < 1 .or. nptcls < 1 ) THROW_HARD('joint2D_candidate_table: invalid allocation dimensions')
        call self%kill
        allocate(self%cand(topk,nptcls), self%pinds(nptcls), self%ncand(nptcls), self%hard_rank(nptcls),&
            &self%initial_hard_rank(nptcls), self%reject_reason(nptcls), self%entropy(nptcls),&
            &self%initial_entropy(nptcls), self%norm_entropy(nptcls), self%winner_weight(nptcls),&
            &self%expected_loss(nptcls), self%initial_expected_loss(nptcls), self%loss_delta(nptcls),&
            &self%particle_weight(nptcls), self%base_shift(2,nptcls), self%likelihood_scale(nptcls),&
            &self%shift_provenance(topk,nptcls),&
            &self%accepted(nptcls))
        self%cand              = joint2D_candidate()
        self%pinds             = 0
        self%ncand             = 0
        self%hard_rank         = 0
        self%initial_hard_rank = 0
        self%reject_reason     = RELIABILITY_EMPTY
        self%entropy           = 0.
        self%initial_entropy   = 0.
        self%norm_entropy      = 0.
        self%winner_weight     = 0.
        self%expected_loss     = 0.
        self%initial_expected_loss = 0.
        self%loss_delta        = 0.
        self%particle_weight   = 0.
        self%base_shift        = 0.
        self%likelihood_scale  = 1.
        self%shift_provenance  = SHIFT_PROVENANCE_INVALID
        self%accepted          = .false.
    end subroutine allocate_blank_table

    subroutine recover_column_pinds( self )
        class(joint2D_candidate_table), intent(inout) :: self
        integer :: iptcl

        call require_allocated(self, 'column-pind recovery requested before build/read')
        do iptcl = 1, size(self%ncand)
            if( self%pinds(iptcl) > 0 ) cycle
            if( self%ncand(iptcl) > 0 ) self%pinds(iptcl) = self%cand(1,iptcl)%pind
        end do
    end subroutine recover_column_pinds

    integer function find_pind_column( self, pind ) result( col )
        class(joint2D_candidate_table), intent(in) :: self
        integer,                        intent(in) :: pind
        integer :: iptcl

        col = 0
        if( pind < 1 ) return
        call require_allocated(self, 'particle lookup requested before build/read')
        do iptcl = 1, size(self%ncand)
            if( self%pinds(iptcl) == pind )then
                col = iptcl
                return
            endif
            if( self%ncand(iptcl) > 0 .and. self%cand(1,iptcl)%pind == pind )then
                col = iptcl
                return
            endif
        end do
    end function find_pind_column

    subroutine copy_candidate_column( src, src_col, dst, dst_col )
        class(joint2D_candidate_table), intent(in)    :: src
        integer,                        intent(in)    :: src_col
        class(joint2D_candidate_table), intent(inout) :: dst
        integer,                        intent(in)    :: dst_col

        dst%cand(:,dst_col)       = src%cand(:,src_col)
        dst%pinds(dst_col)        = src%pinds(src_col)
        dst%ncand(dst_col)        = src%ncand(src_col)
        dst%hard_rank(dst_col)    = src%hard_rank(src_col)
        dst%initial_hard_rank(dst_col) = src%initial_hard_rank(src_col)
        dst%reject_reason(dst_col)= src%reject_reason(src_col)
        dst%entropy(dst_col)      = src%entropy(src_col)
        dst%initial_entropy(dst_col) = src%initial_entropy(src_col)
        dst%norm_entropy(dst_col) = src%norm_entropy(src_col)
        dst%winner_weight(dst_col)= src%winner_weight(src_col)
        dst%expected_loss(dst_col)= src%expected_loss(src_col)
        dst%initial_expected_loss(dst_col) = src%initial_expected_loss(src_col)
        dst%loss_delta(dst_col)   = src%loss_delta(src_col)
        dst%particle_weight(dst_col) = src%particle_weight(src_col)
        dst%base_shift(:,dst_col) = src%base_shift(:,src_col)
        dst%likelihood_scale(dst_col) = src%likelihood_scale(src_col)
        dst%shift_provenance(:,dst_col) = src%shift_provenance(:,src_col)
        dst%accepted(dst_col)     = src%accepted(src_col)
    end subroutine copy_candidate_column

    logical function candidates_equal( lhs, rhs, tol ) result( equal )
        type(joint2D_candidate), intent(in) :: lhs, rhs
        real,                    intent(in) :: tol
        equal = lhs%pind == rhs%pind .and. lhs%icls == rhs%icls .and. lhs%inpl == rhs%inpl .and.&
            &lhs%rank == rhs%rank .and. abs(lhs%dist - rhs%dist) <= tol .and.&
            &abs(lhs%logit - rhs%logit) <= tol .and. abs(lhs%weight - rhs%weight) <= tol .and.&
            &abs(lhs%eff_weight - rhs%eff_weight) <= tol .and. abs(lhs%x - rhs%x) <= tol .and.&
            &abs(lhs%y - rhs%y) <= tol .and. (lhs%has_sh .eqv. rhs%has_sh) .and.&
            &(lhs%hard .eqv. rhs%hard)
    end function candidates_equal

    subroutine mix_candidate( h, cand )
        integer(kind=8),        intent(inout) :: h
        type(joint2D_candidate),intent(in)    :: cand
        call mix_int64(h, cand%pind)
        call mix_int64(h, cand%icls)
        call mix_int64(h, cand%inpl)
        call mix_int64(h, cand%rank)
        call mix_real64(h, cand%dist)
        call mix_real64(h, cand%logit)
        call mix_real64(h, cand%weight)
        call mix_real64(h, cand%eff_weight)
        call mix_real64(h, cand%x)
        call mix_real64(h, cand%y)
        if( cand%has_sh )then
            call mix_int64(h, 1)
        else
            call mix_int64(h, 0)
        endif
        if( cand%hard )then
            call mix_int64(h, 1)
        else
            call mix_int64(h, 0)
        endif
    end subroutine mix_candidate

    subroutine mix_int64( h, val )
        integer(kind=8), intent(inout) :: h
        integer,         intent(in)    :: val
        h = modulo(h * 1103515245_8 + int(val, kind=8) + 12345_8, 2147483647_8)
    end subroutine mix_int64

    subroutine mix_real64( h, val )
        integer(kind=8), intent(inout) :: h
        real,            intent(in)    :: val
        real(kind=8) :: clipped
        if( val /= val )then
            call mix_int64(h, -214748)
            return
        endif
        clipped = max(-1.0e6_8, min(1.0e6_8, real(val, kind=8)))
        call mix_int64(h, int(nint(clipped * 1000.0_8)))
    end subroutine mix_real64

    integer function count_nonfinite_records( self ) result( nbad )
        class(joint2D_candidate_table), intent(in) :: self
        integer :: iptcl, irank

        nbad = 0
        do iptcl = 1, size(self%ncand)
            if( .not. finite_real(self%entropy(iptcl)) ) nbad = nbad + 1
            if( .not. finite_real(self%winner_weight(iptcl)) ) nbad = nbad + 1
            if( .not. finite_real(self%expected_loss(iptcl)) ) nbad = nbad + 1
            do irank = 1, self%ncand(iptcl)
                if( .not. finite_real(self%cand(irank,iptcl)%dist) ) nbad = nbad + 1
                if( .not. finite_real(self%cand(irank,iptcl)%logit) ) nbad = nbad + 1
                if( .not. finite_real(self%cand(irank,iptcl)%weight) ) nbad = nbad + 1
                if( .not. finite_real(self%cand(irank,iptcl)%eff_weight) ) nbad = nbad + 1
            end do
        end do
    end function count_nonfinite_records

end module simple_strategy2D_joint_sgd_candidates
