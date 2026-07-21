program simple_test_joint2D_shadow_stage3
use simple_eul_prob_tab_utils, only: eulprob_should_cache_nll_scale
use simple_type_defs,             only: OBJFUN_CC, OBJFUN_EUCLID
implicit none

call require_true(eulprob_should_cache_nll_scale(.true., 'joint', 'normalized', OBJFUN_EUCLID, .false.),&
    &'stage-3 normalized scoring caches the observational Gaussian-NLL scale')
call require_true(eulprob_should_cache_nll_scale(.true., 'joint', 'gaussian_nll', OBJFUN_EUCLID, .false.),&
    &'active joint scoring caches the Gaussian-NLL scale')
call require_true(.not. eulprob_should_cache_nll_scale(.false., 'joint', 'normalized', OBJFUN_EUCLID, .false.),&
    &'disabled diagnostics do not cache a shadow scale')
call require_true(.not. eulprob_should_cache_nll_scale(.true., 'cavg_only', 'normalized', OBJFUN_EUCLID, .false.),&
    &'non-joint mode does not cache a shadow scale')
call require_true(.not. eulprob_should_cache_nll_scale(.true., 'joint', 'invalid', OBJFUN_EUCLID, .false.),&
    &'unknown likelihood units do not produce diagnostics')
call require_true(.not. eulprob_should_cache_nll_scale(.true., 'joint', 'normalized', OBJFUN_CC, .false.),&
    &'correlation scoring has no Gaussian-NLL scale')
call require_true(.not. eulprob_should_cache_nll_scale(.true., 'joint', 'normalized', OBJFUN_EUCLID, .true.),&
    &'denominator objective does not use the Gaussian-NLL calibration')

write(*,'(A)') 'simple_test_joint2D_shadow_stage3 complete'

contains

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond )then
            write(*,'(A)') 'simple_test_joint2D_shadow_stage3 failed: '//trim(msg)
            error stop 1
        endif
    end subroutine require_true

end program simple_test_joint2D_shadow_stage3
