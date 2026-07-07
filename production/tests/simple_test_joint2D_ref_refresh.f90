program simple_test_joint2D_ref_refresh
use simple_core_module_api
use simple_strategy2D_joint_sgd_refs, only: joint2D_ref_refresh_policy, JOINT2D_REF_SEMANTICS
implicit none

#include "simple_local_flags.inc"

type(joint2D_ref_refresh_policy) :: policy, empty_policy

call policy%new('start2Drefs.mrc', 7)
call require_true(trim(policy%semantics) == JOINT2D_REF_SEMANTICS,&
    &'reference semantics are one_iteration_lag')
call require_true(policy%is_one_iteration_lag(), 'policy reports one-iteration-lagged semantics')
call require_true(.not. policy%refresh_within_iter, 'policy never refreshes references within an iteration')
call require_true(policy%has_input_refs(), 'policy records non-empty input refs')
call require_true(trim(policy%refs_in) == 'start2Drefs.mrc', 'policy preserves input refs')
call require_true(trim(policy%refs_out) == 'cavgs_iter007.mrc', 'policy maps iteration to merged output refs')
call require_true(trim(policy%refs_even_out) == 'cavgs_iter007_even.mrc',&
    &'policy maps iteration to even output refs')
call require_true(trim(policy%refs_odd_out) == 'cavgs_iter007_odd.mrc',&
    &'policy maps iteration to odd output refs')
call policy%require_input_refs('unit-test')
call policy%write_diag('unit-test')

call empty_policy%new('', 7)
call require_true(.not. empty_policy%has_input_refs(), 'empty input refs are rejected by validity predicate')
call require_true(empty_policy%is_one_iteration_lag(), 'empty-input policy still preserves refresh semantics')

write(logfhandle,'(A)') 'simple_test_joint2D_ref_refresh complete'

contains

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond ) THROW_HARD('simple_test_joint2D_ref_refresh failed: '//trim(msg))
    end subroutine require_true

end program simple_test_joint2D_ref_refresh
