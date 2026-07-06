!@descr: Compact top-K candidate table for 2D joint-SGD latent updates
module simple_strategy2D_joint_sgd_candidates
use simple_core_module_api
use simple_type_defs, only: ptcl_ref
implicit none

public :: joint2D_candidate, joint2D_candidate_table, JOINT2D_CANDIDATES_FNAME
private

#include "simple_local_flags.inc"

character(len=*), parameter :: JOINT2D_CANDIDATES_FNAME = 'joint2D_topk_candidates.dat'
integer,          parameter :: JOINT2D_CANDIDATES_VERSION = 2
integer,          parameter :: RELIABILITY_OK           = 0
integer,          parameter :: RELIABILITY_EMPTY        = 1
integer,          parameter :: RELIABILITY_TOO_FEW      = 2
integer,          parameter :: RELIABILITY_HIGH_ENTROPY = 3

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

type :: joint2D_candidate_table
    type(joint2D_candidate), allocatable :: cand(:,:)        !< top-K candidates (topk,nptcls)
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
    real,                    allocatable :: particle_weight(:) !< effective particle weight after gates
    real,                    allocatable :: base_shift(:,:)  !< pre-assignment/base shift (2,nptcls)
    logical,                 allocatable :: accepted(:)      !< reliability gate result
contains
    procedure :: build_from_loc_tab
    procedure :: set_base_shifts
    procedure :: optimize_logits
    procedure :: apply_reliability
    procedure :: write_hard_assignments
    procedure :: write_table
    procedure :: read_table
    procedure :: export_batch
    procedure :: write_diag
    procedure :: kill => kill_candidate_table
end type joint2D_candidate_table

contains

    subroutine build_from_loc_tab( self, loc_tab, topk, tau, tau_min )
        class(joint2D_candidate_table), intent(inout) :: self
        type(ptcl_ref),                 intent(in)    :: loc_tab(:,:)
        integer,                        intent(in)    :: topk
        real,                           intent(in)    :: tau
        real,                           intent(in)    :: tau_min
        integer :: icls, iptcl, nclasses, nptcls
        real    :: tau_eff

        if( topk < 1 ) THROW_HARD('joint2D_candidate_table: topk must be >= 1')
        tau_eff = max(tau, tau_min)
        if( tau_eff <= 0. ) THROW_HARD('joint2D_candidate_table: tau_eff must be > 0')

        call self%kill
        nclasses = size(loc_tab, 1)
        nptcls   = size(loc_tab, 2)
        allocate(self%cand(topk,nptcls), self%ncand(nptcls), self%hard_rank(nptcls),&
            &self%initial_hard_rank(nptcls), self%reject_reason(nptcls), self%entropy(nptcls),&
            &self%initial_entropy(nptcls), self%norm_entropy(nptcls), self%winner_weight(nptcls),&
            &self%expected_loss(nptcls), self%initial_expected_loss(nptcls), self%loss_delta(nptcls),&
            &self%particle_weight(nptcls), self%base_shift(2,nptcls), self%accepted(nptcls))
        self%cand            = joint2D_candidate()
        self%ncand           = 0
        self%hard_rank       = 0
        self%initial_hard_rank = 0
        self%reject_reason   = RELIABILITY_EMPTY
        self%entropy         = 0.
        self%initial_entropy = 0.
        self%norm_entropy    = 0.
        self%winner_weight   = 0.
        self%expected_loss   = 0.
        self%initial_expected_loss = 0.
        self%loss_delta      = 0.
        self%particle_weight = 0.
        self%base_shift      = 0.
        self%accepted        = .false.

        do iptcl = 1, nptcls
            do icls = 1, nclasses
                if( .not. valid_ref(loc_tab(icls,iptcl)) ) cycle
                call insert_candidate(self, iptcl, topk, loc_tab(icls,iptcl))
            end do
            call finalize_particle(self, iptcl, tau_eff)
        end do
        call self%apply_reliability(1, 1.0)
    end subroutine build_from_loc_tab

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

    subroutine optimize_logits( self, inner_its, eta_latent, tau, tau_min )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: inner_its
        real,                           intent(in)    :: eta_latent
        real,                           intent(in)    :: tau
        real,                           intent(in)    :: tau_min
        integer :: iter, iptcl
        real    :: tau_eff

        call require_allocated(self, 'latent-logit optimization requested before build/read')
        if( inner_its < 1 ) THROW_HARD('joint2D_candidate_table: inner_its must be >= 1')
        if( eta_latent <= 0. ) THROW_HARD('joint2D_candidate_table: eta_latent must be > 0')
        tau_eff = max(tau, tau_min)
        if( tau_eff <= 0. ) THROW_HARD('joint2D_candidate_table: tau_eff must be > 0')

        do iter = 1, inner_its
            do iptcl = 1, size(self%ncand)
                call optimize_particle_logits(self, iptcl, eta_latent, tau_eff)
                call refresh_particle(self, iptcl, tau_eff)
            end do
        end do
        do iptcl = 1, size(self%ncand)
            if( self%ncand(iptcl) > 0 )then
                self%loss_delta(iptcl) = self%initial_expected_loss(iptcl) - self%expected_loss(iptcl)
            endif
        end do
    end subroutine optimize_logits

    subroutine apply_reliability( self, min_cands, max_entropy )
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
        write(unit=funit, iostat=io_stat) self%ncand, self%hard_rank, self%initial_hard_rank, self%reject_reason
        call fileiochk('joint2D_candidate_table; write_table(ints); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%entropy, self%initial_entropy, self%norm_entropy, self%winner_weight
        call fileiochk('joint2D_candidate_table; write_table(reals1); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%expected_loss, self%initial_expected_loss, self%loss_delta
        call fileiochk('joint2D_candidate_table; write_table(reals2); file: '//trim(fname), io_stat)
        write(unit=funit, iostat=io_stat) self%particle_weight, self%base_shift
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
        if( version /= JOINT2D_CANDIDATES_VERSION )then
            THROW_HARD('joint2D_candidate_table: unsupported file version')
        endif
        if( topk < 1 .or. nptcls < 1 )then
            THROW_HARD('joint2D_candidate_table: invalid file dimensions')
        endif
        allocate(self%cand(topk,nptcls), self%ncand(nptcls), self%hard_rank(nptcls),&
            &self%initial_hard_rank(nptcls), self%reject_reason(nptcls), self%entropy(nptcls),&
            &self%initial_entropy(nptcls), self%norm_entropy(nptcls), self%winner_weight(nptcls),&
            &self%expected_loss(nptcls), self%initial_expected_loss(nptcls), self%loss_delta(nptcls),&
            &self%particle_weight(nptcls), self%base_shift(2,nptcls), self%accepted(nptcls))
        read(unit=funit, iostat=io_stat) self%cand
        call fileiochk('joint2D_candidate_table; read_table(cand); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%ncand, self%hard_rank, self%initial_hard_rank, self%reject_reason
        call fileiochk('joint2D_candidate_table; read_table(ints); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%entropy, self%initial_entropy, self%norm_entropy, self%winner_weight
        call fileiochk('joint2D_candidate_table; read_table(reals1); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%expected_loss, self%initial_expected_loss, self%loss_delta
        call fileiochk('joint2D_candidate_table; read_table(reals2); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%particle_weight, self%base_shift
        call fileiochk('joint2D_candidate_table; read_table(reals3); file: '//trim(fname), io_stat)
        read(unit=funit, iostat=io_stat) self%accepted
        call fileiochk('joint2D_candidate_table; read_table(flags); file: '//trim(fname), io_stat)
        close(funit)
    end subroutine read_table

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
            if( nc < 1 .or. .not. self%accepted(iptcl) ) cycle
            do irank = 1, nc
                refs(irank,iloc) = ref_from_candidate(self, irank, iptcl)
                weights(irank,iloc) = self%cand(irank,iptcl)%eff_weight
            end do
        end do
    end subroutine export_batch

    subroutine write_diag( self, label )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: label
        integer :: nptcls, topk, nonempty, empty_count, accepted_count, too_few_count, entropy_count
        integer :: winner_churn_count
        real    :: avg_ncand, avg_entropy, avg_initial_entropy, avg_norm_entropy, avg_winner_weight
        real    :: avg_initial_loss, avg_expected_loss, avg_loss_delta

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
        winner_churn_count = count((self%ncand > 0) .and. (self%initial_hard_rank /= self%hard_rank))
        avg_ncand = 0.
        avg_entropy = 0.
        avg_initial_entropy = 0.
        avg_norm_entropy = 0.
        avg_winner_weight = 0.
        avg_initial_loss = 0.
        avg_expected_loss = 0.
        avg_loss_delta = 0.
        if( nptcls > 0 ) avg_ncand = real(sum(self%ncand)) / real(nptcls)
        if( nonempty > 0 )then
            avg_entropy       = sum(self%entropy,       mask=self%ncand > 0) / real(nonempty)
            avg_initial_entropy = sum(self%initial_entropy, mask=self%ncand > 0) / real(nonempty)
            avg_norm_entropy  = sum(self%norm_entropy,  mask=self%ncand > 0) / real(nonempty)
            avg_winner_weight = sum(self%winner_weight, mask=self%ncand > 0) / real(nonempty)
            avg_initial_loss  = sum(self%initial_expected_loss, mask=self%ncand > 0) / real(nonempty)
            avg_expected_loss = sum(self%expected_loss, mask=self%ncand > 0) / real(nonempty)
            avg_loss_delta    = sum(self%loss_delta, mask=self%ncand > 0) / real(nonempty)
        endif
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,I0)')&
            &'>>> JOINT2D SGD TOPK:', trim(label), 'topk=', topk, 'nptcls=', nptcls, 'empty=', empty_count,&
            &'accepted=', accepted_count, 'too_few=', too_few_count, 'high_entropy=', entropy_count
        write(logfhandle,'(A,1X,A,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3,1X,A,I0)')&
            &'>>> JOINT2D SGD TOPK STATS:', trim(label), 'avg_ncand=', avg_ncand,&
            &'avg_entropy=', avg_entropy, 'avg_norm_entropy=', avg_norm_entropy,&
            &'avg_winner_weight=', avg_winner_weight, 'winner_churn=', winner_churn_count
        write(logfhandle,'(A,1X,A,1X,A,ES12.4,1X,A,ES12.4,1X,A,ES12.4,1X,A,F7.3)')&
            &'>>> JOINT2D SGD LATENT:', trim(label), 'avg_initial_loss=', avg_initial_loss,&
            &'avg_final_loss=', avg_expected_loss, 'avg_loss_delta=', avg_loss_delta,&
            &'avg_initial_entropy=', avg_initial_entropy
    end subroutine write_diag

    subroutine kill_candidate_table( self )
        class(joint2D_candidate_table), intent(inout) :: self
        if( allocated(self%cand)            ) deallocate(self%cand)
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
        if( allocated(self%accepted)        ) deallocate(self%accepted)
    end subroutine kill_candidate_table

    logical function valid_ref( ref ) result( is_valid )
        type(ptcl_ref), intent(in) :: ref
        is_valid = ref%pind > 0 .and. ref%icls > 0 .and. ref%inpl > 0
        if( is_valid )then
            is_valid = (ref%dist == ref%dist) .and. (abs(ref%dist) < huge(ref%dist) / 2.0)
        endif
    end function valid_ref

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
        end do
        self%cand(pos,iptcl) = newcand
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

    subroutine finalize_particle( self, iptcl, tau_eff )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        real,                           intent(in)    :: tau_eff
        integer :: irank, nc

        nc = self%ncand(iptcl)
        if( nc < 1 ) return

        do irank = 1, nc
            self%cand(irank,iptcl)%logit = -self%cand(irank,iptcl)%dist
        end do
        call refresh_particle(self, iptcl, tau_eff)
        self%initial_hard_rank(iptcl)     = self%hard_rank(iptcl)
        self%initial_entropy(iptcl)       = self%entropy(iptcl)
        self%initial_expected_loss(iptcl) = self%expected_loss(iptcl)
        self%loss_delta(iptcl)            = 0.
    end subroutine finalize_particle

    subroutine optimize_particle_logits( self, iptcl, eta_latent, tau_eff )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        real,                           intent(in)    :: eta_latent, tau_eff
        integer :: irank, nc
        real    :: grad, loss

        nc = self%ncand(iptcl)
        if( nc < 1 ) return
        loss = self%expected_loss(iptcl)
        do irank = 1, nc
            grad = (self%cand(irank,iptcl)%weight / tau_eff) * (self%cand(irank,iptcl)%dist - loss)
            self%cand(irank,iptcl)%logit = self%cand(irank,iptcl)%logit - eta_latent * grad
        end do
    end subroutine optimize_particle_logits

    subroutine refresh_particle( self, iptcl, tau_eff )
        class(joint2D_candidate_table), intent(inout) :: self
        integer,                        intent(in)    :: iptcl
        real,                           intent(in)    :: tau_eff
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
            score = self%cand(irank,iptcl)%logit / tau_eff
            max_score = max(max_score, score)
        end do

        denom = 0.
        do irank = 1, nc
            score = self%cand(irank,iptcl)%logit / tau_eff
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
            score = self%cand(irank,iptcl)%logit / tau_eff
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

end module simple_strategy2D_joint_sgd_candidates
