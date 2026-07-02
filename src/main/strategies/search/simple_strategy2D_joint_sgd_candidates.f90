!@descr: Compact top-K candidate table for 2D joint-SGD latent updates
module simple_strategy2D_joint_sgd_candidates
use simple_core_module_api
use simple_type_defs, only: ptcl_ref
implicit none

public :: joint2D_candidate, joint2D_candidate_table
private

#include "simple_local_flags.inc"

type :: joint2D_candidate
    integer :: pind = 0
    integer :: icls = 0
    integer :: inpl = 0
    integer :: rank = 0
    real    :: dist = 0.
    real    :: logit = 0.
    real    :: weight = 0.
    real    :: x = 0.
    real    :: y = 0.
    logical :: has_sh = .false.
    logical :: hard = .false.
end type joint2D_candidate

type :: joint2D_candidate_table
    type(joint2D_candidate), allocatable :: cand(:,:)        !< top-K candidates (topk,nptcls)
    integer,                 allocatable :: ncand(:)         !< valid candidates retained per particle
    integer,                 allocatable :: hard_rank(:)     !< selected straight-through rank per particle
    real,                    allocatable :: entropy(:)       !< entropy over retained soft weights
    real,                    allocatable :: winner_weight(:) !< soft weight of the hard winner
contains
    procedure :: build_from_loc_tab
    procedure :: write_hard_assignments
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
            &self%entropy(nptcls), self%winner_weight(nptcls))
        self%cand          = joint2D_candidate()
        self%ncand         = 0
        self%hard_rank     = 0
        self%entropy       = 0.
        self%winner_weight = 0.

        do iptcl = 1, nptcls
            do icls = 1, nclasses
                if( .not. valid_ref(loc_tab(icls,iptcl)) ) cycle
                call insert_candidate(self, iptcl, topk, loc_tab(icls,iptcl))
            end do
            call finalize_particle(self, iptcl, tau_eff)
        end do
    end subroutine build_from_loc_tab

    subroutine write_hard_assignments( self, assgn_map, empty_is_error )
        class(joint2D_candidate_table), intent(in)    :: self
        type(ptcl_ref),                 intent(inout) :: assgn_map(:)
        logical, optional,              intent(in)    :: empty_is_error
        logical :: l_empty_is_error
        integer :: iptcl, hard, nptcls

        if( .not. allocated(self%ncand) ) THROW_HARD('joint2D_candidate_table: hard assignments requested before build')
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

    subroutine write_diag( self, label )
        class(joint2D_candidate_table), intent(in) :: self
        character(len=*),               intent(in) :: label
        integer :: nptcls, topk, nonempty, empty_count
        real    :: avg_ncand, avg_entropy, avg_winner_weight

        if( .not. allocated(self%ncand) )then
            write(logfhandle,'(A,1X,A)') '>>> JOINT2D SGD TOPK:', trim(label)//' table not allocated'
            return
        endif
        nptcls      = size(self%ncand)
        topk        = size(self%cand, 1)
        nonempty    = count(self%ncand > 0)
        empty_count = nptcls - nonempty
        avg_ncand = 0.
        avg_entropy = 0.
        avg_winner_weight = 0.
        if( nptcls > 0 ) avg_ncand = real(sum(self%ncand)) / real(nptcls)
        if( nonempty > 0 )then
            avg_entropy       = sum(self%entropy,       mask=self%ncand > 0) / real(nonempty)
            avg_winner_weight = sum(self%winner_weight, mask=self%ncand > 0) / real(nonempty)
        endif
        write(logfhandle,'(A,1X,A,1X,A,I0,1X,A,I0,1X,A,I0,1X,A,F7.3,1X,A,F7.3,1X,A,F7.3)')&
            &'>>> JOINT2D SGD TOPK:', trim(label), 'topk=', topk, 'nptcls=', nptcls, 'empty=', empty_count,&
            &'avg_ncand=', avg_ncand, 'avg_entropy=', avg_entropy, 'avg_winner_weight=', avg_winner_weight
    end subroutine write_diag

    subroutine kill_candidate_table( self )
        class(joint2D_candidate_table), intent(inout) :: self
        if( allocated(self%cand)          ) deallocate(self%cand)
        if( allocated(self%ncand)         ) deallocate(self%ncand)
        if( allocated(self%hard_rank)     ) deallocate(self%hard_rank)
        if( allocated(self%entropy)       ) deallocate(self%entropy)
        if( allocated(self%winner_weight) ) deallocate(self%winner_weight)
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
        real    :: max_logit, denom, w, best_weight

        nc = self%ncand(iptcl)
        if( nc < 1 ) return

        max_logit = -huge(1.0)
        do irank = 1, nc
            self%cand(irank,iptcl)%rank  = irank
            self%cand(irank,iptcl)%hard  = .false.
            self%cand(irank,iptcl)%logit = -self%cand(irank,iptcl)%dist / tau_eff
            max_logit = max(max_logit, self%cand(irank,iptcl)%logit)
        end do

        denom = 0.
        do irank = 1, nc
            denom = denom + exp(self%cand(irank,iptcl)%logit - max_logit)
        end do
        if( denom <= 0. .or. denom /= denom )then
            self%cand(1,iptcl)%weight = 1.
            self%hard_rank(iptcl) = 1
            self%winner_weight(iptcl) = 1.
            self%cand(1,iptcl)%hard = .true.
            return
        endif

        best_weight = -1.
        self%hard_rank(iptcl) = 1
        do irank = 1, nc
            w = exp(self%cand(irank,iptcl)%logit - max_logit) / denom
            self%cand(irank,iptcl)%weight = w
            if( w > 0. ) self%entropy(iptcl) = self%entropy(iptcl) - w * log(w)
            if( w > best_weight )then
                best_weight = w
                self%hard_rank(iptcl) = irank
            endif
        end do
        self%winner_weight(iptcl) = self%cand(self%hard_rank(iptcl),iptcl)%weight
        self%cand(self%hard_rank(iptcl),iptcl)%hard = .true.
    end subroutine finalize_particle

end module simple_strategy2D_joint_sgd_candidates
