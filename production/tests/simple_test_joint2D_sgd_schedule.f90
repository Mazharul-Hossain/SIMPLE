program simple_test_joint2D_sgd_schedule
use simple_joint2D_sgd_schedule, only: joint2D_sgd_active_for_iteration,&
    &joint2D_sgd_active_for_policy, joint2D_sgd_activation_for_stage,&
    &joint2D_sgd_activation_valid, JOINT2D_SGD_WARMUP_ITS, JOINT2D_SGD_ALTERNATE_UNTIL
implicit none

integer :: iter
character(len=9) :: activation

call require_true(JOINT2D_SGD_WARMUP_ITS == 10, 'warmup ends after iteration 10')
call require_true(JOINT2D_SGD_ALTERNATE_UNTIL == 20, 'alternation ends after iteration 20')
do iter = 1, 10
    call require_true(.not. joint2D_sgd_active_for_iteration(iter), 'iterations 1-10 keep SGD off')
end do
do iter = 11, 20
    if( mod(iter, 2) == 1 )then
        call require_true(joint2D_sgd_active_for_iteration(iter), 'odd transition iteration uses joint SGD')
    else
        call require_true(.not. joint2D_sgd_active_for_iteration(iter),&
            &'even transition iteration keeps SGD off')
    endif
end do
do iter = 21, 30
    call require_true(joint2D_sgd_active_for_iteration(iter), 'iterations after 20 use joint SGD')
end do
call require_true(.not. joint2D_sgd_active_for_iteration(0), 'nonpositive iteration is not joint SGD')

call require_true(joint2D_sgd_activation_valid('auto'), 'auto is a valid internal activation')
call require_true(.not. joint2D_sgd_activation_valid('auto', .false.), 'auto is not a valid stage-4 mode')
call require_true(joint2D_sgd_activation_valid('off', .false.), 'off is a valid stage-4 mode')
call require_true(joint2D_sgd_activation_valid('alternate', .false.), 'alternate is a valid stage-4 mode')
call require_true(joint2D_sgd_activation_valid('on', .false.), 'on is a valid stage-4 mode')
call require_true(.not. joint2D_sgd_activation_valid('invalid'), 'invalid activation is rejected')

do iter = 1, 3
    activation = joint2D_sgd_activation_for_stage(.true., iter, 'alternate', .false.)
    call require_true(trim(activation) == 'off', 'stages 1-3 keep SGD off')
end do
activation = joint2D_sgd_activation_for_stage(.true., 4, 'off', .false.)
call require_true(trim(activation) == 'off', 'stage 4 accepts off')
activation = joint2D_sgd_activation_for_stage(.true., 4, 'alternate', .false.)
call require_true(trim(activation) == 'alternate', 'stage 4 accepts alternate')
activation = joint2D_sgd_activation_for_stage(.true., 4, 'on', .false.)
call require_true(trim(activation) == 'on', 'stage 4 accepts on')
do iter = 5, 6
    activation = joint2D_sgd_activation_for_stage(.true., iter, 'off', .false.)
    call require_true(trim(activation) == 'on', 'stages 5 and later use joint SGD')
end do
activation = joint2D_sgd_activation_for_stage(.true., 7, 'on', .true.)
call require_true(trim(activation) == 'off', 'terminal pass keeps SGD off')
activation = joint2D_sgd_activation_for_stage(.false., 6, 'on', .false.)
call require_true(trim(activation) == 'off', 'sgd=no keeps every stage off')

do iter = 1, 5
    if( mod(iter, 2) == 0 )then
        call require_true(joint2D_sgd_active_for_policy('alternate', iter, 100 + iter),&
            &'alternate uses joint SGD on even local iterations')
    else
        call require_true(.not. joint2D_sgd_active_for_policy('alternate', iter, 100 + iter),&
            &'alternate keeps SGD off on odd local iterations')
    endif
end do
call require_true(.not. joint2D_sgd_active_for_policy('off', 2, 22), 'off policy stays off')
call require_true(joint2D_sgd_active_for_policy('on', 1, 1), 'on policy starts immediately')
call require_true(joint2D_sgd_active_for_policy('auto', 1, 21), 'auto preserves standalone global schedule')

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
