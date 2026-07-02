program simple_test_joint2D_candidate_table
use simple_core_module_api
use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table
use simple_type_defs, only: ptcl_ref
implicit none

#include "simple_local_flags.inc"

type(ptcl_ref) :: loc_tab(5,4)
type(joint2D_candidate_table) :: tab
integer :: i
real    :: weight_sum

call init_loc_tab(loc_tab)

call tab%build_from_loc_tab(loc_tab, 3, 1.0, 0.1)
call require_true(tab%ncand(1) == 3, 'particle 1 retains three candidates')
call require_true(tab%cand(1,1)%icls == 2, 'particle 1 rank 1 tie-breaks to lower class')
call require_true(tab%cand(2,1)%icls == 3, 'particle 1 rank 2 keeps next tied class')
call require_true(tab%cand(3,1)%icls == 5, 'particle 1 skips invalid inpl=0 candidate')
call require_true(tab%hard_rank(1) == 1, 'particle 1 hard rank is first candidate')
call require_true(tab%cand(1,1)%hard, 'particle 1 hard flag is set')
weight_sum = sum(tab%cand(1:tab%ncand(1),1)%weight)
call require_close(weight_sum, 1.0, 1.0e-6, 'particle 1 weights sum to one')

call require_true(tab%ncand(2) == 3, 'particle 2 keeps three large-distance candidates')
weight_sum = sum(tab%cand(1:tab%ncand(2),2)%weight)
call require_close(weight_sum, 1.0, 1.0e-6, 'particle 2 weights sum to one')
do i = 1, tab%ncand(2)
    call require_true(tab%cand(i,2)%weight == tab%cand(i,2)%weight, 'particle 2 finite weight')
end do

call require_true(tab%ncand(3) == 0, 'empty particle column has zero candidates')
call require_true(tab%hard_rank(3) == 0, 'empty particle column has zero hard rank')

call tab%kill
call tab%build_from_loc_tab(loc_tab, 1, 1.0, 0.1)
call require_true(tab%ncand(1) == 1, 'topk=1 keeps one candidate')
call require_close(tab%cand(1,1)%weight, 1.0, 1.0e-6, 'topk=1 candidate weight is one')
call require_true(tab%hard_rank(1) == 1, 'topk=1 hard rank is one')

call tab%write_diag('unit-test')
call tab%kill
write(logfhandle,'(A)') 'simple_test_joint2D_candidate_table complete'

contains

    subroutine init_loc_tab( tab_in )
        type(ptcl_ref), intent(inout) :: tab_in(:,:)
        tab_in = ptcl_ref()
        call set_ref(tab_in(1,1), 101, 1, 10, 3.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(2,1), 101, 2, 20, 1.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(3,1), 101, 3,  5, 1.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(4,1), 101, 4,  0, -10.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(5,1), 101, 5, 15, 2.0, 1.5, -2.0, .true.)

        call set_ref(tab_in(1,2), 102, 1, 11, 1000000.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(2,2), 102, 2, 12, 1000001.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(3,2), 102, 3, 13, 1000002.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(4,2), 102, 4, 14, huge(1.0), 0.0, 0.0, .false.)

        call set_ref(tab_in(1,4), 104, 1, 21, 5.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(2,4), 104, 2, 22, 4.0, 0.0, 0.0, .false.)
    end subroutine init_loc_tab

    subroutine set_ref( ref, pind, icls, inpl, dist, x, y, has_sh )
        type(ptcl_ref), intent(inout) :: ref
        integer,        intent(in)    :: pind, icls, inpl
        real,           intent(in)    :: dist, x, y
        logical,        intent(in)    :: has_sh
        ref%pind = pind
        ref%icls = icls
        ref%inpl = inpl
        ref%dist = dist
        ref%x = x
        ref%y = y
        ref%has_sh = has_sh
    end subroutine set_ref

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond ) THROW_HARD('simple_test_joint2D_candidate_table failed: '//trim(msg))
    end subroutine require_true

    subroutine require_close( got, expected, tol, msg )
        real,             intent(in) :: got, expected, tol
        character(len=*), intent(in) :: msg
        if( abs(got - expected) > tol )then
            write(logfhandle,'(A,1X,ES12.4,1X,A,1X,ES12.4)') 'got=', got, 'expected=', expected
            THROW_HARD('simple_test_joint2D_candidate_table failed: '//trim(msg))
        endif
    end subroutine require_close

end program simple_test_joint2D_candidate_table
