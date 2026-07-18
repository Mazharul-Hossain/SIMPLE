!@descr: iteration activation policy for joint 2D SGD
module simple_joint2D_sgd_schedule
implicit none
private

integer, parameter, public :: JOINT2D_SGD_WARMUP_ITS      = 10
integer, parameter, public :: JOINT2D_SGD_ALTERNATE_UNTIL = 20
integer, parameter :: SGD_ACTIVATION_LEN = 9
public :: joint2D_sgd_active_for_iteration, joint2D_sgd_active_for_policy
public :: joint2D_sgd_activation_for_stage, joint2D_sgd_activation_valid
public :: joint2D_sgd_batch_size, joint2D_sgd_likelihood_units

contains

    pure function joint2D_sgd_likelihood_units( active ) result( units )
        logical, intent(in) :: active
        character(len=12) :: units
        if( active )then
            units = 'gaussian_nll'
        else
            units = 'normalized'
        endif
    end function joint2D_sgd_likelihood_units

    pure integer function joint2D_sgd_batch_size( nactive, batch_frac, max_samples ) result( batch_size )
        integer, intent(in) :: nactive, max_samples
        real,    intent(in) :: batch_frac
        if( nactive <= 0 )then
            batch_size = 0
            return
        endif
        batch_size = min(nactive, max(1, nint(batch_frac * real(nactive))))
        if( max_samples > 0 ) batch_size = min(batch_size, max_samples)
    end function joint2D_sgd_batch_size

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

    pure logical function joint2D_sgd_active_for_policy( activation, stage_iter, which_iter ) result( active )
        character(len=*), intent(in) :: activation
        integer,          intent(in) :: stage_iter, which_iter
        select case(trim(activation))
            case('auto')
                active = joint2D_sgd_active_for_iteration(which_iter)
            case('off')
                active = .false.
            case('alternate')
                active = stage_iter > 0 .and. mod(stage_iter, 2) == 0
            case('on')
                active = stage_iter > 0
            case DEFAULT
                active = .false.
        end select
    end function joint2D_sgd_active_for_policy

    pure function joint2D_sgd_activation_for_stage( requested, stage, stage4_mode, terminal ) result( activation )
        logical,          intent(in) :: requested, terminal
        integer,          intent(in) :: stage
        character(len=*), intent(in) :: stage4_mode
        character(len=SGD_ACTIVATION_LEN) :: activation
        if( .not. requested .or. terminal .or. stage <= 3 )then
            activation = 'off'
        else if( stage == 4 )then
            activation = trim(stage4_mode)
        else
            activation = 'on'
        endif
    end function joint2D_sgd_activation_for_stage

    pure logical function joint2D_sgd_activation_valid( activation, allow_auto ) result( valid )
        character(len=*), intent(in) :: activation
        logical, optional, intent(in) :: allow_auto
        logical :: l_allow_auto
        l_allow_auto = .true.
        if( present(allow_auto) ) l_allow_auto = allow_auto
        select case(trim(activation))
            case('off','alternate','on')
                valid = .true.
            case('auto')
                valid = l_allow_auto
            case DEFAULT
                valid = .false.
        end select
    end function joint2D_sgd_activation_valid

end module simple_joint2D_sgd_schedule
