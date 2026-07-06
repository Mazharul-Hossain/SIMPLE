program simple_test_cavg_sgd_optimizer
use iso_c_binding, only: c_float_complex
use simple_core_module_api
use simple_cavg_sgd_optimizer, only: cavg_sgd_optimizer
implicit none

#include "simple_local_flags.inc"

type(cavg_sgd_optimizer) :: opt
complex(kind=c_float_complex) :: oldc(2,2,1), statsc(2,2,1)
real :: oldr(2,2,1), statsr(2,2,1), rho(2,2,1)

opt%eta0 = 1.0
oldc  = cmplx(2.0, 1.0, kind=c_float_complex)
rho   = 4.0
statsc = cmplx(40.0, 20.0, kind=c_float_complex)
call opt%preconditioned_cavg_update_inplace(oldc, rho, statsc)
call require_close(real(statsc(1,1,1)), 40.0, 1.0e-6, 'eta=1 keeps weighted numerator real part')
call require_close(aimag(statsc(1,1,1)), 20.0, 1.0e-6, 'eta=1 keeps weighted numerator imaginary part')

opt%eta0 = 0.25
oldc  = cmplx(2.0, 1.0, kind=c_float_complex)
rho   = 4.0
statsc = cmplx(40.0, 20.0, kind=c_float_complex)
call opt%preconditioned_cavg_update_inplace(oldc, rho, statsc)
call require_close(real(statsc(1,1,1)), 16.0, 1.0e-6, 'fractional eta moves numerator toward batch real part')
call require_close(aimag(statsc(1,1,1)), 8.0, 1.0e-6, 'fractional eta moves numerator toward batch imaginary part')

opt%eta0 = 0.5
oldc  = cmplx(3.0, 4.0, kind=c_float_complex)
rho   = 0.0
statsc = cmplx(999.0, -999.0, kind=c_float_complex)
call opt%preconditioned_cavg_update_inplace(oldc, rho, statsc)
call require_close(real(statsc(1,1,1)), 3.0, 1.0e-6, 'zero rho preserves old real part')
call require_close(aimag(statsc(1,1,1)), 4.0, 1.0e-6, 'zero rho preserves old imaginary part')
call require_true(real(statsc(1,1,1)) == real(statsc(1,1,1)), 'zero rho output is finite')

opt%eta0 = 0.5
oldr  = 5.0
rho   = 2.0
statsr = 30.0
call opt%preconditioned_cavg_update_inplace(oldr, rho, statsr)
call require_close(statsr(1,1,1), 20.0, 1.0e-6, 'real preconditioned update matches expected numerator')

opt%eta0 = 0.25
oldr  = 10.0
statsr = 30.0
call opt%blend_sufficient_stats_inplace(oldr, statsr)
call require_close(statsr(1,1,1), 15.0, 1.0e-6, 'cavg_only blend behavior is unchanged')

write(logfhandle,'(A)') 'simple_test_cavg_sgd_optimizer complete'

contains

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond ) THROW_HARD('simple_test_cavg_sgd_optimizer failed: '//trim(msg))
    end subroutine require_true

    subroutine require_close( got, expected, tol, msg )
        real,             intent(in) :: got, expected, tol
        character(len=*), intent(in) :: msg
        if( abs(got - expected) > tol )then
            write(logfhandle,'(A,1X,ES12.4,1X,A,1X,ES12.4)') 'got=', got, 'expected=', expected
            THROW_HARD('simple_test_cavg_sgd_optimizer failed: '//trim(msg))
        endif
    end subroutine require_close

end program simple_test_cavg_sgd_optimizer
