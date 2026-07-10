!@descr: iteration activation policy for joint 2D SGD
module simple_joint2D_sgd_schedule
implicit none
private

integer, parameter, public :: JOINT2D_SGD_WARMUP_ITS      = 10
integer, parameter, public :: JOINT2D_SGD_ALTERNATE_UNTIL = 20
public :: joint2D_sgd_active_for_iteration

contains

    pure logical function joint2D_sgd_active_for_iteration( which_iter ) result( active )
        integer, intent(in) :: which_iter
        if( which_iter <= JOINT2D_SGD_WARMUP_ITS )then
            active = .false.
        else if( which_iter <= JOINT2D_SGD_ALTERNATE_UNTIL )then
            ! Start the transition with joint SGD at iteration 11, then alternate.
            active = mod(which_iter - JOINT2D_SGD_WARMUP_ITS, 2) == 1
        else
            active = .true.
        endif
    end function joint2D_sgd_active_for_iteration

end module simple_joint2D_sgd_schedule
