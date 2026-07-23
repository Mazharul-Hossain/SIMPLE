program simple_test_joint2D_direct_shift
use simple_core_module_api, only: dp
use simple_pftc_shsrch_grad, only: bounded_shift_trial
implicit none

real(dp) :: shift(2), shift_gradient(2), shift_limits(2,2), trial_shift(2)

shift = 0.0_dp
shift_gradient = [3.0_dp, 4.0_dp]
shift_limits(:,1) = -1.0_dp
shift_limits(:,2) =  1.0_dp
trial_shift = bounded_shift_trial(shift, shift_gradient, 0.5_dp, shift_limits)
call require_close(trial_shift, [-0.3_dp,-0.4_dp], 1.0e-12_dp,&
    &'direct step is normalized so eta is a pixel-length bound')

shift_limits(:,1) = -0.25_dp
shift_limits(:,2) =  0.25_dp
trial_shift = bounded_shift_trial(shift, shift_gradient, 0.5_dp, shift_limits)
call require_close(trial_shift, [-0.25_dp,-0.25_dp], 1.0e-12_dp,&
    &'direct step is projected into the legal shift box')

shift = [0.1_dp,-0.2_dp]
trial_shift = bounded_shift_trial(shift, [0.0_dp,0.0_dp], 0.5_dp, shift_limits)
call require_close(trial_shift, shift, 1.0e-12_dp, 'zero gradient preserves the original shift')

write(*,'(A)') 'joint2D bounded direct-shift regression: PASS'

contains

    subroutine require_close( actual, expected, tolerance, msg )
        real(dp),         intent(in) :: actual(2), expected(2), tolerance
        character(len=*), intent(in) :: msg
        if( maxval(abs(actual - expected)) > tolerance )then
            write(*,'(A)') 'simple_test_joint2D_direct_shift failed: '//trim(msg)
            error stop 1
        endif
    end subroutine require_close

end program simple_test_joint2D_direct_shift
