!@descr: small helper for class-average sufficient-statistics SGD updates
module simple_cavg_sgd_optimizer
use iso_c_binding, only: c_float_complex
use simple_core_module_api
use simple_parameters, only: parameters
implicit none

public :: cavg_sgd_optimizer
private

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
    generic   :: blend_sufficient_stats => blend_real3, blend_complex3
    generic   :: blend_sufficient_stats_inplace => blend_real3_inplace, blend_complex3_inplace
    procedure :: write_diag
    procedure :: kill
end type cavg_sgd_optimizer

contains

    subroutine new( self, params, which_iter )
        class(cavg_sgd_optimizer), intent(inout) :: self
        class(parameters),         intent(in)    :: params
        integer,                   intent(in)    :: which_iter
        self%active     = params%l_sgd .and. (trim(params%sgd_mode) == 'cavg_only')
        self%diag       = params%l_sgd_diag
        self%which_iter = which_iter
        self%eta0       = params%sgd_eta
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

    subroutine write_diag( self, label )
        class(cavg_sgd_optimizer), intent(in) :: self
        character(len=*),          intent(in) :: label
        if( .not. self%active ) return
        if( .not. self%diag ) return
        write(logfhandle,'(a,1x,a,1x,a,i0,1x,a,f8.4)') '>>> CAVG SGD:', trim(label), &
            &'iter=', self%which_iter, 'eta=', self%eta()
    end subroutine write_diag

    subroutine kill( self )
        class(cavg_sgd_optimizer), intent(inout) :: self
        self%active     = .false.
        self%diag       = .true.
        self%which_iter = 0
        self%eta0       = 0.2
        self%eta_decay  = 'const'
    end subroutine kill

end module simple_cavg_sgd_optimizer
