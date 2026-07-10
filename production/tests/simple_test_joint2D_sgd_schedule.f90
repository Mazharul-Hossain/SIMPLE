program simple_test_joint2D_sgd_schedule
use simple_joint2D_sgd_schedule, only: joint2D_sgd_active_for_iteration,&
    &JOINT2D_SGD_WARMUP_ITS, JOINT2D_SGD_ALTERNATE_UNTIL
implicit none

integer :: iter

call require_true(JOINT2D_SGD_WARMUP_ITS == 10, 'warmup ends after iteration 10')
call require_true(JOINT2D_SGD_ALTERNATE_UNTIL == 20, 'alternation ends after iteration 20')
do iter = 1, 10
    call require_true(.not. joint2D_sgd_active_for_iteration(iter), 'iterations 1-10 use legacy likelihood')
end do
do iter = 11, 20
    if( mod(iter, 2) == 1 )then
        call require_true(joint2D_sgd_active_for_iteration(iter), 'odd transition iteration uses joint SGD')
    else
        call require_true(.not. joint2D_sgd_active_for_iteration(iter),&
            &'even transition iteration uses legacy likelihood')
    endif
end do
do iter = 21, 30
    call require_true(joint2D_sgd_active_for_iteration(iter), 'iterations after 20 use joint SGD')
end do
call require_true(.not. joint2D_sgd_active_for_iteration(0), 'nonpositive iteration is not joint SGD')

write(*,'(A)') 'simple_test_joint2D_sgd_schedule complete'

contains

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond )then
            write(*,'(A)') 'simple_test_joint2D_sgd_schedule failed: '//trim(msg)
            error stop 1
        endif
    end subroutine require_true

end program simple_test_joint2D_sgd_schedule
