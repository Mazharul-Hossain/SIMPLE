!@descr: Reference refresh policy for shared-memory 2D joint-SGD
module simple_strategy2D_joint_sgd_refs
use simple_core_module_api
implicit none

public :: joint2D_ref_refresh_policy, JOINT2D_REF_SEMANTICS
private

#include "simple_local_flags.inc"

character(len=*), parameter :: JOINT2D_REF_SEMANTICS = 'one_iteration_lag'

type :: joint2D_ref_refresh_policy
    character(len=STDLEN) :: semantics = JOINT2D_REF_SEMANTICS
    logical               :: refresh_within_iter = .false.
    integer               :: which_iter = 0
    character(len=STDLEN) :: refs_in = ''
    character(len=STDLEN) :: refs_out = ''
    character(len=STDLEN) :: refs_even_out = ''
    character(len=STDLEN) :: refs_odd_out = ''
contains
    procedure :: new => new_ref_refresh_policy
    procedure :: has_input_refs
    procedure :: is_one_iteration_lag
    procedure :: require_input_refs
    procedure :: write_diag
end type joint2D_ref_refresh_policy

contains

    subroutine new_ref_refresh_policy( self, refs_in, which_iter )
        class(joint2D_ref_refresh_policy), intent(inout) :: self
        character(len=*),                  intent(in)    :: refs_in
        integer,                           intent(in)    :: which_iter

        if( which_iter < 1 ) THROW_HARD('joint2D_ref_refresh_policy: which_iter must be >= 1')
        self%semantics           = JOINT2D_REF_SEMANTICS
        self%refresh_within_iter = .false.
        self%which_iter          = which_iter
        self%refs_in             = trim(refs_in)
        self%refs_out            = CAVGS_ITER_FBODY//int2str_pad(which_iter,3)//MRC_EXT
        self%refs_even_out       = CAVGS_ITER_FBODY//int2str_pad(which_iter,3)//'_even'//MRC_EXT
        self%refs_odd_out        = CAVGS_ITER_FBODY//int2str_pad(which_iter,3)//'_odd'//MRC_EXT
    end subroutine new_ref_refresh_policy

    logical function has_input_refs( self ) result( has_refs )
        class(joint2D_ref_refresh_policy), intent(in) :: self
        has_refs = len_trim(self%refs_in) > 0
    end function has_input_refs

    logical function is_one_iteration_lag( self ) result( is_lagged )
        class(joint2D_ref_refresh_policy), intent(in) :: self
        is_lagged = trim(self%semantics) == JOINT2D_REF_SEMANTICS .and. (.not. self%refresh_within_iter)
    end function is_one_iteration_lag

    subroutine require_input_refs( self, label )
        class(joint2D_ref_refresh_policy), intent(in) :: self
        character(len=*),                  intent(in) :: label
        if( .not. self%has_input_refs() )then
            THROW_HARD('joint 2D SGD reference refresh requires non-empty refs in '//trim(label))
        endif
    end subroutine require_input_refs

    subroutine write_diag( self, label )
        class(joint2D_ref_refresh_policy), intent(in) :: self
        character(len=*),                  intent(in) :: label

        write(logfhandle,'(A,1X,A,1X,A,A,1X,A,I0,1X,A,L1)')&
            &'>>> JOINT2D SGD REFS:', trim(label), 'semantics=', trim(self%semantics),&
            &'iter=', self%which_iter, 'refresh_within_iter=', self%refresh_within_iter
        write(logfhandle,'(A,1X,A,1X,A,A)')&
            &'>>> JOINT2D SGD REFS IN:', trim(label), 'refs=', trim(self%refs_in)
        write(logfhandle,'(A,1X,A,1X,A,A,1X,A,A,1X,A,A)')&
            &'>>> JOINT2D SGD REFS OUT:', trim(label), 'refs=', trim(self%refs_out),&
            &'even=', trim(self%refs_even_out), 'odd=', trim(self%refs_odd_out)
    end subroutine write_diag

end module simple_strategy2D_joint_sgd_refs
