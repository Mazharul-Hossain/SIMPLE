!@descr: Joint latent-variable SGD scaffold for cluster2D/abinitio2D
module simple_strategy2D_joint_sgd
use simple_core_module_api
use simple_parameters, only: parameters
use simple_builder,    only: builder
use simple_cmdline,    only: cmdline
use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table
implicit none

public :: cluster2D_joint_sgd_exec
private
#include "simple_local_flags.inc"

contains

    subroutine cluster2D_joint_sgd_exec( params, build, cline, which_iter, converged )
        class(parameters), target, intent(in)    :: params
        class(builder),    target, intent(in)    :: build
        class(cmdline),            intent(inout) :: cline
        integer,                   intent(in)    :: which_iter
        logical,                   intent(inout) :: converged
        type(joint2D_candidate_table) :: candidates
        converged = .false.
        write(logfhandle,'(a)') '>>> JOINT 2D SGD REQUESTED'
        write(logfhandle,'(a,i0)') 'which_iter     : ', which_iter
        write(logfhandle,'(a,a)')  'sgd_mode       : ', trim(params%sgd_mode)
        write(logfhandle,'(a,a)')  'sgd_latent     : ', trim(params%sgd_latent)
        write(logfhandle,'(a,i0)') 'sgd_topk       : ', params%sgd_topk
        write(logfhandle,'(a,i0)') 'sgd_inner_its  : ', params%sgd_inner_its
        write(logfhandle,'(a)') 'joint SGD will make the matcher a candidate generator, not the assignment owner'
        write(logfhandle,'(a)') 'joint SGD candidate-table module is available; integration is the next milestone'
        call candidates%kill
        THROW_HARD('sgd_mode=joint requires the top-K candidate-table optimizer; scaffold only in this pass')
    end subroutine cluster2D_joint_sgd_exec

end module simple_strategy2D_joint_sgd
