!@descr: small helper for class-average sufficient-statistics SGD updates
module simple_cavg_sgd_optimizer
use iso_c_binding, only: c_float_complex
use simple_core_module_api
use simple_parameters, only: parameters
implicit none

#include "simple_local_flags.inc"

public :: cavg_sgd_optimizer, cavg_sgd_diagnostics
private

type :: cavg_sgd_diagnostics
    integer  :: n_updated      = 0
    integer  :: n_preserved    = 0
    integer  :: n_nonfinite    = 0
    real     :: support_sum    = 0.0
    real     :: support_min    = huge(1.0)
    real     :: support_max    = 0.0
    real(dp) :: grad_sq_sum    = 0.0_dp
    real(dp) :: step_sq_sum    = 0.0_dp
    real(dp) :: old_sq_sum     = 0.0_dp
  contains
    procedure :: reset => cavg_sgd_diag_reset
    procedure :: record_preserved => cavg_sgd_diag_record_preserved
end type cavg_sgd_diagnostics

type :: cavg_sgd_optimizer
    logical                 :: active     = .false.
    logical                 :: diag       = .true.
    integer                 :: which_iter = 0
    real                    :: eta0       = 0.2
    character(len=STDLEN)   :: eta_decay  = 'const'
  contains
    procedure :: new
    procedure :: eta
    procedure :: blend_real3
    procedure :: blend_complex3
    procedure :: blend_real3_inplace
    procedure :: blend_complex3_inplace
    procedure :: preconditioned_real3_inplace
    procedure :: preconditioned_complex3_inplace
    generic   :: blend_sufficient_stats => blend_real3, blend_complex3
    generic   :: blend_sufficient_stats_inplace => blend_real3_inplace, blend_complex3_inplace
    generic   :: preconditioned_cavg_update_inplace => preconditioned_real3_inplace, preconditioned_complex3_inplace
    procedure :: write_diag
    procedure :: write_update_diag
    procedure :: kill
end type cavg_sgd_optimizer

contains

    subroutine cavg_sgd_diag_reset( self )
        class(cavg_sgd_diagnostics), intent(inout) :: self
        self%n_updated   = 0
        self%n_preserved = 0
        self%n_nonfinite = 0
        self%support_sum = 0.0
        self%support_min = huge(1.0)
        self%support_max = 0.0
        self%grad_sq_sum = 0.0_dp
        self%step_sq_sum = 0.0_dp
        self%old_sq_sum  = 0.0_dp
    end subroutine cavg_sgd_diag_reset

    subroutine cavg_sgd_diag_record_preserved( self )
        class(cavg_sgd_diagnostics), intent(inout) :: self
        self%n_preserved = self%n_preserved + 1
    end subroutine cavg_sgd_diag_record_preserved

    subroutine new( self, params, which_iter )
        class(cavg_sgd_optimizer), intent(inout) :: self
        class(parameters),         intent(in)    :: params
        integer,                   intent(in)    :: which_iter
        self%active     = params%l_sgd .and. &
            &((trim(params%sgd_mode) == 'cavg_only') .or. (trim(params%sgd_mode) == 'joint'))
        self%diag       = params%l_sgd_diag
        self%which_iter = which_iter
        if( trim(params%sgd_mode) == 'joint' )then
            self%eta0 = params%sgd_eta_cavg
        else
            self%eta0 = params%sgd_eta
        endif
        self%eta_decay  = trim(params%sgd_eta_decay)
    end subroutine new

    real function eta( self ) result( eta_t )
        class(cavg_sgd_optimizer), intent(in) :: self
        select case(trim(self%eta_decay))
            case('const')
                eta_t = self%eta0
            case DEFAULT
                eta_t = self%eta0
        end select
    end function eta

    subroutine blend_real3( self, prev_stats, batch_stats, out_stats )
        class(cavg_sgd_optimizer), intent(in)  :: self
        real,                      intent(in)  :: prev_stats(:,:,:)
        real,                      intent(in)  :: batch_stats(:,:,:)
        real,                      intent(out) :: out_stats(:,:,:)
        real :: eta_t
        eta_t = self%eta()
        out_stats = (1.0 - eta_t) * prev_stats + eta_t * batch_stats
    end subroutine blend_real3

    subroutine blend_complex3( self, prev_stats, batch_stats, out_stats )
        class(cavg_sgd_optimizer), intent(in)  :: self
        complex(kind=c_float_complex), intent(in)  :: prev_stats(:,:,:)
        complex(kind=c_float_complex), intent(in)  :: batch_stats(:,:,:)
        complex(kind=c_float_complex), intent(out) :: out_stats(:,:,:)
        real :: eta_t
        eta_t = self%eta()
        out_stats = cmplx(1.0 - eta_t, 0.0, kind=c_float_complex) * prev_stats &
            &+ cmplx(eta_t, 0.0, kind=c_float_complex) * batch_stats
    end subroutine blend_complex3

    subroutine blend_real3_inplace( self, prev_stats, stats )
        class(cavg_sgd_optimizer), intent(in)    :: self
        real,                      intent(in)    :: prev_stats(:,:,:)
        real,                      intent(inout) :: stats(:,:,:)
        real :: eta_t
        eta_t = self%eta()
        stats = (1.0 - eta_t) * prev_stats + eta_t * stats
    end subroutine blend_real3_inplace

    subroutine blend_complex3_inplace( self, prev_stats, stats )
        class(cavg_sgd_optimizer),      intent(in)    :: self
        complex(kind=c_float_complex),  intent(in)    :: prev_stats(:,:,:)
        complex(kind=c_float_complex),  intent(inout) :: stats(:,:,:)
        real :: eta_t
        eta_t = self%eta()
        stats = cmplx(1.0 - eta_t, 0.0, kind=c_float_complex) * prev_stats &
            &+ cmplx(eta_t, 0.0, kind=c_float_complex) * stats
    end subroutine blend_complex3_inplace

    subroutine preconditioned_real3_inplace( self, old_cavg, rho, stats, diag, support, throw_on_nonfinite )
        class(cavg_sgd_optimizer), intent(in)    :: self
        real,                      intent(in)    :: old_cavg(:,:,:)
        real,                      intent(in)    :: rho(:,:,:)
        real,                      intent(inout) :: stats(:,:,:)
        type(cavg_sgd_diagnostics), optional, intent(inout) :: diag
        real,                       optional, intent(in)    :: support
        logical,                    optional, intent(in)    :: throw_on_nonfinite
        integer :: i, j, k
        integer :: n_nonfinite
        real    :: eta_t, rho_ijk, precond, grad, step, updated
        real    :: support_val
        logical :: l_throw
        real(dp) :: grad_sq, step_sq, old_sq
        eta_t = self%eta()
        grad_sq = 0.0_dp
        step_sq = 0.0_dp
        old_sq  = 0.0_dp
        n_nonfinite = 0
        support_val = 0.0
        if( present(support) ) support_val = support
        l_throw = .false.
        if( present(throw_on_nonfinite) ) l_throw = throw_on_nonfinite
        do k = 1, size(stats,3)
            do j = 1, size(stats,2)
                do i = 1, size(stats,1)
                    rho_ijk = rho(i,j,k)
                    if( .not. finite_real(rho_ijk) .or. .not. finite_real(old_cavg(i,j,k)) .or. &
                        &.not. finite_real(stats(i,j,k)) )then
                        n_nonfinite = n_nonfinite + 1
                        cycle
                    endif
                    if( rho_ijk > TINY )then
                        precond = max(rho_ijk, TINY)
                        grad = rho_ijk * old_cavg(i,j,k) - stats(i,j,k)
                        step = -eta_t * grad / precond
                        updated = rho_ijk * (old_cavg(i,j,k) + step)
                        if( finite_real(grad) .and. finite_real(step) .and. finite_real(updated) )then
                            stats(i,j,k) = updated
                            grad_sq = grad_sq + real(grad * grad, dp)
                            step_sq = step_sq + real(step * step, dp)
                            old_sq  = old_sq  + real(old_cavg(i,j,k) * old_cavg(i,j,k), dp)
                        else
                            n_nonfinite = n_nonfinite + 1
                        endif
                    else
                        stats(i,j,k) = old_cavg(i,j,k)
                    endif
                enddo
            enddo
        enddo
        if( present(diag) ) call update_diag(diag, support_val, grad_sq, step_sq, old_sq, n_nonfinite)
        if( l_throw .and. n_nonfinite > 0 )then
            THROW_HARD('CAVG SGD preconditioned real update produced nonfinite values')
        endif
    end subroutine preconditioned_real3_inplace

    subroutine preconditioned_complex3_inplace( self, old_cavg, rho, stats, diag, support, throw_on_nonfinite )
        class(cavg_sgd_optimizer),     intent(in)    :: self
        complex(kind=c_float_complex), intent(in)    :: old_cavg(:,:,:)
        real,                          intent(in)    :: rho(:,:,:)
        complex(kind=c_float_complex), intent(inout) :: stats(:,:,:)
        type(cavg_sgd_diagnostics), optional, intent(inout) :: diag
        real,                       optional, intent(in)    :: support
        logical,                    optional, intent(in)    :: throw_on_nonfinite
        integer :: i, j, k
        integer :: n_nonfinite
        real    :: eta_t, rho_ijk, precond
        real    :: support_val
        logical :: l_throw
        real(dp) :: grad_sq, step_sq, old_sq
        complex(kind=c_float_complex) :: grad, step, updated
        eta_t = self%eta()
        grad_sq = 0.0_dp
        step_sq = 0.0_dp
        old_sq  = 0.0_dp
        n_nonfinite = 0
        support_val = 0.0
        if( present(support) ) support_val = support
        l_throw = .false.
        if( present(throw_on_nonfinite) ) l_throw = throw_on_nonfinite
        do k = 1, size(stats,3)
            do j = 1, size(stats,2)
                do i = 1, size(stats,1)
                    rho_ijk = rho(i,j,k)
                    if( .not. finite_real(rho_ijk) .or. .not. finite_complex(old_cavg(i,j,k)) .or. &
                        &.not. finite_complex(stats(i,j,k)) )then
                        n_nonfinite = n_nonfinite + 1
                        cycle
                    endif
                    if( rho_ijk > TINY )then
                        precond = max(rho_ijk, TINY)
                        grad = cmplx(rho_ijk, 0.0, kind=c_float_complex) * old_cavg(i,j,k) - stats(i,j,k)
                        step = -cmplx(eta_t / precond, 0.0, kind=c_float_complex) * grad
                        updated = cmplx(rho_ijk, 0.0, kind=c_float_complex) * (old_cavg(i,j,k) + step)
                        if( finite_complex(grad) .and. finite_complex(step) .and. finite_complex(updated) )then
                            stats(i,j,k) = updated
                            grad_sq = grad_sq + real(abs(grad), dp)**2
                            step_sq = step_sq + real(abs(step), dp)**2
                            old_sq  = old_sq  + real(abs(old_cavg(i,j,k)), dp)**2
                        else
                            n_nonfinite = n_nonfinite + 1
                        endif
                    else
                        stats(i,j,k) = old_cavg(i,j,k)
                    endif
                enddo
            enddo
        enddo
        if( present(diag) ) call update_diag(diag, support_val, grad_sq, step_sq, old_sq, n_nonfinite)
        if( l_throw .and. n_nonfinite > 0 )then
            THROW_HARD('CAVG SGD preconditioned complex update produced nonfinite values')
        endif
    end subroutine preconditioned_complex3_inplace

    subroutine write_diag( self, label )
        class(cavg_sgd_optimizer), intent(in) :: self
        character(len=*),          intent(in) :: label
        if( .not. self%active ) return
        if( .not. self%diag ) return
        write(logfhandle,'(a,1x,a,1x,a,i0,1x,a,f8.4)') '>>> CAVG SGD:', trim(label), &
            &'iter=', self%which_iter, 'eta=', self%eta()
    end subroutine write_diag

    subroutine write_update_diag( self, label, diag )
        class(cavg_sgd_optimizer),   intent(in) :: self
        character(len=*),            intent(in) :: label
        type(cavg_sgd_diagnostics),  intent(in) :: diag
        real :: support_min, support_mean, support_max
        real :: grad_norm, step_norm, rel_step_norm
        if( .not. self%active ) return
        if( .not. self%diag ) return
        support_min  = 0.0
        support_mean = 0.0
        support_max  = 0.0
        if( diag%n_updated > 0 )then
            support_min  = diag%support_min
            support_mean = diag%support_sum / real(diag%n_updated)
            support_max  = diag%support_max
        endif
        grad_norm = real(sqrt(diag%grad_sq_sum))
        step_norm = real(sqrt(diag%step_sq_sum))
        rel_step_norm = 0.0
        if( diag%old_sq_sum > DTINY ) rel_step_norm = real(sqrt(diag%step_sq_sum / diag%old_sq_sum))
        write(logfhandle,'(a,1x,a,1x,a,i0,1x,a,i0,1x,a,i0,1x,a,i0)') '>>> CAVG SGD UPDATE:',&
            &trim(label), 'updated=', diag%n_updated, 'preserved=', diag%n_preserved,&
            &'nonfinite=', diag%n_nonfinite, 'iter=', self%which_iter
        write(logfhandle,'(a,1x,a,1x,a,es12.4,1x,a,es12.4,1x,a,es12.4)') '>>> CAVG SGD SUPPORT:',&
            &trim(label), 'min=', support_min, 'mean=', support_mean, 'max=', support_max
        write(logfhandle,'(a,1x,a,1x,a,es12.4,1x,a,es12.4,1x,a,es12.4)') '>>> CAVG SGD NORMS:',&
            &trim(label), 'grad=', grad_norm, 'step=', step_norm, 'rel_step=', rel_step_norm
    end subroutine write_update_diag

    subroutine kill( self )
        class(cavg_sgd_optimizer), intent(inout) :: self
        self%active     = .false.
        self%diag       = .true.
        self%which_iter = 0
        self%eta0       = 0.2
        self%eta_decay  = 'const'
    end subroutine kill

    subroutine update_diag( diag, support, grad_sq, step_sq, old_sq, n_nonfinite )
        type(cavg_sgd_diagnostics), intent(inout) :: diag
        real,                       intent(in)    :: support
        real(dp),                   intent(in)    :: grad_sq, step_sq, old_sq
        integer,                    intent(in)    :: n_nonfinite
        diag%n_updated = diag%n_updated + 1
        diag%support_sum = diag%support_sum + support
        diag%support_min = min(diag%support_min, support)
        diag%support_max = max(diag%support_max, support)
        diag%grad_sq_sum = diag%grad_sq_sum + grad_sq
        diag%step_sq_sum = diag%step_sq_sum + step_sq
        diag%old_sq_sum  = diag%old_sq_sum  + old_sq
        diag%n_nonfinite = diag%n_nonfinite + n_nonfinite
    end subroutine update_diag

    logical function finite_real( val ) result( is_finite )
        real, intent(in) :: val
        is_finite = (val == val) .and. (abs(val) < huge(val))
    end function finite_real

    logical function finite_complex( val ) result( is_finite )
        complex(kind=c_float_complex), intent(in) :: val
        is_finite = finite_real(real(val)) .and. finite_real(aimag(val))
    end function finite_complex

end module simple_cavg_sgd_optimizer
