program simple_test_joint2D_candidate_table
use simple_core_module_api
use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table
use simple_type_defs, only: ptcl_ref
implicit none

#include "simple_local_flags.inc"

character(len=*), parameter :: ROUNDTRIP_FNAME = 'joint2D_candidate_table_test.dat'
type(ptcl_ref) :: loc_tab(5,4)
type(ptcl_ref) :: assgn_map(4)
type(ptcl_ref), allocatable :: batch_refs(:,:)
type(joint2D_candidate_table) :: tab, tab_roundtrip, tab_shift, tab_inpl
real, allocatable :: batch_weights(:,:)
integer, allocatable :: batch_ncands(:)
integer :: i
integer :: old_inpl
real    :: base_shifts(2,4), weight_sum, expected_weight
real    :: p4_initial_weight, p4_initial_loss, p4_initial_entropy
real    :: old_shift(2), new_shift(2), step_norm
logical :: updated

call init_loc_tab(loc_tab)
call init_base_shifts(base_shifts)

call tab%build_from_loc_tab(loc_tab, 3, 1.0, 0.1)
call tab%set_base_shifts(base_shifts)
expected_weight = exp(-4.0) / (exp(-4.0) + exp(-5.0))
call require_close(tab%cand(1,4)%weight, expected_weight, 1.0e-6,&
    &'initial weights match softmax(-dist/tau)')
call require_close(tab%cand(1,4)%logit, -4.0, 1.0e-6, 'initial logit is raw negative distance')
call require_close(tab%cand(1,1)%weight, tab%cand(2,1)%weight, 1.0e-6,&
    &'equal-distance candidates start tied')
p4_initial_weight = tab%cand(1,4)%weight
p4_initial_loss = tab%expected_loss(4)
p4_initial_entropy = tab%entropy(4)
call tab%optimize_logits(8, 1.0, 1.0, 0.1)
call require_true(tab%cand(1,4)%weight > p4_initial_weight,&
    &'latent optimization increases weight on lower-distance candidate')
call require_true(tab%expected_loss(4) < p4_initial_loss,&
    &'latent optimization decreases expected candidate loss')
call require_true(tab%loss_delta(4) > 0.0, 'latent optimization records positive loss improvement')
call require_true(tab%entropy(4) < p4_initial_entropy, 'latent optimization lowers entropy for separated candidates')
call require_close(tab%cand(1,1)%weight, tab%cand(2,1)%weight, 1.0e-6,&
    &'equal-distance candidates remain tied after optimization')
call require_true(tab%hard_rank(1) == 1, 'equal-distance hard winner remains deterministic')
call tab%apply_reliability(2, 0.95)
call require_true(tab%ncand(1) == 3, 'particle 1 retains three candidates')
call require_true(tab%cand(1,1)%icls == 2, 'particle 1 rank 1 tie-breaks to lower class')
call require_true(tab%cand(2,1)%icls == 3, 'particle 1 rank 2 keeps next tied class')
call require_true(tab%cand(3,1)%icls == 5, 'particle 1 skips invalid inpl=0 candidate')
call require_true(tab%hard_rank(1) == 1, 'particle 1 hard rank is first candidate')
call require_true(tab%cand(1,1)%hard, 'particle 1 hard flag is set')
call require_true(tab%accepted(1), 'particle 1 passes reliability gates')
call require_true(tab%accepted(4), 'particle 4 passes reliability gates with two candidates')
call require_close(tab%particle_weight(1), 1.0, 1.0e-6, 'accepted particle has unit particle weight')
call require_close(tab%cand(1,1)%eff_weight, tab%cand(1,1)%weight, 1.0e-6, 'effective candidate weight is q')
call require_close(tab%norm_entropy(1), tab%entropy(1) / log(real(tab%ncand(1))), 1.0e-6,&
    &'normalized entropy is H/log(ncand)')
weight_sum = sum(tab%cand(1:tab%ncand(1),1)%weight)
call require_close(weight_sum, 1.0, 1.0e-6, 'particle 1 weights sum to one')
assgn_map = ptcl_ref()
call tab%write_hard_assignments(assgn_map, empty_is_error=.false.)
call require_true(assgn_map(1)%pind == 101, 'assignment map copies particle index')
call require_true(assgn_map(1)%icls == 2, 'assignment map copies hard class')
call require_true(assgn_map(1)%inpl == 20, 'assignment map copies hard in-plane index')
call require_close(assgn_map(1)%dist, 1.0, 1.0e-6, 'assignment map copies hard distance')
call require_true(assgn_map(1)%npeaks == tab%ncand(1), 'assignment map records retained candidate count')
call require_true(assgn_map(3)%pind == 0, 'empty assignment map entry is left untouched when allowed')

call require_true(tab%ncand(2) == 3, 'particle 2 keeps three large-distance candidates')
weight_sum = sum(tab%cand(1:tab%ncand(2),2)%weight)
call require_close(weight_sum, 1.0, 1.0e-6, 'particle 2 weights sum to one')
do i = 1, tab%ncand(2)
    call require_true(tab%cand(i,2)%weight == tab%cand(i,2)%weight, 'particle 2 finite weight')
end do

call require_true(tab%ncand(3) == 0, 'empty particle column has zero candidates')
call require_true(tab%hard_rank(3) == 0, 'empty particle column has zero hard rank')
call require_true(.not. tab%accepted(3), 'empty particle column is rejected')

call tab%apply_reliability(3, 0.95)
call require_true(.not. tab%accepted(4), 'too-few-candidate particle is rejected')
call require_close(sum(tab%cand(:,4)%eff_weight), 0.0, 1.0e-6, 'rejected candidate weights are zero')
call tab%export_batch(1, 4, batch_refs, batch_weights, batch_ncands)
call require_close(sum(batch_weights(:,4)), 0.0, 1.0e-6, 'too-few-candidate export has zero support')
call tab%apply_reliability(2, 0.50)
call require_true(.not. tab%accepted(1), 'high-entropy particle is rejected')
call require_true(tab%accepted(4), 'reliability gates use post-optimization entropy')
call tab%export_batch(1, 4, batch_refs, batch_weights, batch_ncands)
call require_close(sum(batch_weights(:,1)), 0.0, 1.0e-6, 'high-entropy export has zero support')
call tab%apply_reliability(2, 0.95)

call tab%export_batch(1, 4, batch_refs, batch_weights, batch_ncands)
call require_true(batch_ncands(1) == 3, 'batch export records retained candidate count')
call require_close(batch_refs(1,1)%x, 10.0, 1.0e-6, 'batch export includes base x shift')
call require_close(batch_refs(1,1)%y, 20.0, 1.0e-6, 'batch export includes base y shift')
call require_close(batch_refs(3,1)%x, 11.5, 1.0e-6, 'batch export adds candidate x shift')
call require_close(batch_refs(3,1)%y, 18.0, 1.0e-6, 'batch export adds candidate y shift')
call require_true(batch_refs(1,1)%has_sh, 'batch export materializes total shift')
call require_close(batch_weights(1,1), tab%cand(1,1)%weight, 1.0e-6, 'batch export uses effective weight')
call require_close(sum(batch_weights(:,3)), 0.0, 1.0e-6, 'empty particle exports zero weights')
call require_close(sum(batch_weights(1:batch_ncands(4),4)), 1.0, 1.0e-6, 'two-candidate weights sum to one')
call require_true(all(batch_weights(1:batch_ncands(4),4) > 0.0), 'two-candidate weights are positive')
call require_true(all(batch_weights(1:batch_ncands(4),4) < 1.0), 'two-candidate weights remain fractional')

call tab%apply_inpl_refinement(1, 3, 4, 0.5, 1.0, 0.1, old_inpl=old_inpl, updated=updated)
call require_true(updated, 'in-plane refinement reports update')
call require_true(old_inpl == 15, 'in-plane refinement reports old in-plane index')
call require_true(tab%cand(3,1)%inpl == 4, 'in-plane refinement updates in-plane index')
call require_close(tab%cand(3,1)%dist, 0.5, 1.0e-6, 'in-plane refinement updates candidate distance')
call require_close(tab%cand(3,1)%logit, -0.5, 1.0e-6, 'in-plane refinement resets logit from refined distance')
call require_true(tab%hard_rank(1) == 3, 'in-plane refinement can change hard winner')
call require_true(tab%cand(3,1)%weight > tab%cand(1,1)%weight,&
    &'in-plane refinement increases weight on improved candidate')
call tab%apply_reliability(2, 1.0)
call require_true(tab%accepted(1), 'in-plane-refined particle remains accepted after reliability gates')

call tab_inpl%build_from_loc_tab(loc_tab, 3, 1.0, 0.1)
call tab_inpl%set_base_shifts(base_shifts)
call tab_inpl%apply_inpl_refinement(4, 1, 23, 0.1, 1.0, 0.1, old_inpl=old_inpl, updated=updated)
call require_true(updated, 'two-candidate in-plane refinement reports update')
call require_true(old_inpl == 22, 'two-candidate in-plane refinement reports old in-plane index')
call require_true(tab_inpl%hard_rank(4) == 1, 'two-candidate in-plane refinement keeps best hard rank')
call require_true(tab_inpl%cand(1,4)%weight > 0.95, 'two-candidate in-plane refinement sharpens weight')
call tab_inpl%apply_reliability(2, 0.50)
call require_true(tab_inpl%accepted(4), 'reliability gates use post-in-plane-refinement entropy')
call tab_inpl%apply_inpl_refinement(1, 1, 20, 1.0, 1.0, 0.1, old_inpl=old_inpl, updated=updated)
call require_true(tab_inpl%hard_rank(1) == 1, 'equal-distance in-plane refinement remains deterministic')
call tab_inpl%kill

call del_file(ROUNDTRIP_FNAME)
call tab%write_table(ROUNDTRIP_FNAME)
call tab_roundtrip%read_table(ROUNDTRIP_FNAME)
call require_true(size(tab_roundtrip%cand, 1) == 3, 'roundtrip preserves topk dimension')
call require_true(size(tab_roundtrip%cand, 2) == 4, 'roundtrip preserves particle dimension')
call require_true(tab_roundtrip%accepted(1), 'roundtrip preserves reliability flag')
call require_close(tab_roundtrip%base_shift(1,1), 10.0, 1.0e-6, 'roundtrip preserves base shift')
call require_close(tab_roundtrip%cand(3,1)%eff_weight, tab%cand(3,1)%eff_weight, 1.0e-6,&
    &'roundtrip preserves effective candidate weight')
call require_close(tab_roundtrip%expected_loss(4), tab%expected_loss(4), 1.0e-6,&
    &'roundtrip preserves final expected loss')
call require_close(tab_roundtrip%initial_expected_loss(4), tab%initial_expected_loss(4), 1.0e-6,&
    &'roundtrip preserves initial expected loss')
call require_close(tab_roundtrip%loss_delta(4), tab%loss_delta(4), 1.0e-6,&
    &'roundtrip preserves latent optimizer diagnostics')
call require_true(tab_roundtrip%hard_rank(1) == tab%hard_rank(1), 'roundtrip preserves final hard rank')
call require_true(tab_roundtrip%cand(3,1)%inpl == 4, 'roundtrip preserves refined in-plane index')
call require_close(tab_roundtrip%cand(3,1)%logit, tab%cand(3,1)%logit, 1.0e-6,&
    &'roundtrip preserves refined in-plane logit')
call require_close(tab_roundtrip%cand(3,1)%weight, tab%cand(3,1)%weight, 1.0e-6,&
    &'roundtrip preserves refined in-plane weight')
call tab_roundtrip%kill
call del_file(ROUNDTRIP_FNAME)

call tab_shift%build_from_loc_tab(loc_tab, 3, 1.0, 0.1)
call tab_shift%set_base_shifts(base_shifts)
call tab_shift%apply_shift_refinement(1, 3, [5.5, 2.0], 0.5, 0.25, 1.0, 0.1,&
    &old_shift=old_shift, new_shift=new_shift, step_norm=step_norm, updated=updated)
call require_true(updated, 'shift refinement reports an updated candidate')
call require_close(old_shift(1), 1.5, 1.0e-6, 'shift refinement reports old x')
call require_close(old_shift(2), -2.0, 1.0e-6, 'shift refinement reports old y')
call require_close(new_shift(1), 2.5, 1.0e-6, 'shift refinement damps x toward optimizer shift')
call require_close(new_shift(2), -1.0, 1.0e-6, 'shift refinement damps y toward optimizer shift')
call require_close(step_norm, sqrt(2.0), 1.0e-6, 'shift refinement reports damped step norm')
call require_close(tab_shift%cand(3,1)%dist, 0.5, 1.0e-6, 'shift refinement updates candidate distance')
call require_close(tab_shift%cand(3,1)%logit, -0.5, 1.0e-6, 'shift refinement resets logit from refined distance')
call require_true(tab_shift%hard_rank(1) == 3, 'shift refinement can change hard winner')
call require_true(tab_shift%cand(3,1)%weight > tab_shift%cand(1,1)%weight,&
    &'shift refinement increases weight on improved candidate')
call require_true(tab_shift%loss_delta(1) > 0.0, 'shift refinement records expected-loss improvement')
call tab_shift%apply_reliability(2, 1.0)
call require_true(tab_shift%accepted(1), 'shift-refined particle remains accepted after reliability gates')
call tab_shift%export_batch(1, 1, batch_refs, batch_weights, batch_ncands)
call require_close(batch_refs(3,1)%x, 12.5, 1.0e-6, 'shift-refined export adds damped x to base shift')
call require_close(batch_refs(3,1)%y, 19.0, 1.0e-6, 'shift-refined export adds damped y to base shift')
call tab_shift%apply_shift_refinement(4, 2, [2.0, 3.0], 3.0, 1.0, 1.0, 0.1,&
    &old_shift=old_shift, new_shift=new_shift, step_norm=step_norm, updated=updated)
call require_true(updated, 'full-eta shift refinement reports update')
call require_close(new_shift(1), 2.0, 1.0e-6, 'full-eta shift refinement uses optimizer x')
call require_close(new_shift(2), 3.0, 1.0e-6, 'full-eta shift refinement uses optimizer y')
call require_true(tab_shift%hard_rank(4) == 2, 'full-eta shift refinement can change two-candidate winner')
call tab_shift%kill

call tab%kill
call tab%build_from_loc_tab(loc_tab, 1, 1.0, 0.1)
call tab%set_base_shifts(base_shifts)
call tab%optimize_logits(8, 1.0, 1.0, 0.1)
call tab%apply_reliability(2, 0.0)
call require_true(tab%ncand(1) == 1, 'topk=1 keeps one candidate')
call require_close(tab%cand(1,1)%weight, 1.0, 1.0e-6, 'topk=1 candidate weight is one')
call require_true(tab%hard_rank(1) == 1, 'topk=1 hard rank is one')
call require_close(tab%loss_delta(1), 0.0, 1.0e-6, 'topk=1 optimizer is no-op on expected loss')
call require_true(tab%accepted(1), 'topk=1 lowers effective min candidate count to one')
assgn_map = ptcl_ref()
call tab%write_hard_assignments(assgn_map, empty_is_error=.false.)
call tab%export_batch(1, 4, batch_refs, batch_weights, batch_ncands)
call require_true(batch_refs(1,1)%icls == assgn_map(1)%icls, 'topk=1 export class equals hard assignment')
call require_true(batch_refs(1,1)%inpl == assgn_map(1)%inpl, 'topk=1 export in-plane equals hard assignment')
call require_close(batch_weights(1,1), 1.0, 1.0e-6, 'topk=1 export weight is one')
call tab%apply_shift_refinement(1, 1, [4.0, -4.0], 0.25, 0.5, 1.0, 0.1,&
    &old_shift=old_shift, new_shift=new_shift, step_norm=step_norm, updated=updated)
call require_true(updated, 'topk=1 shift refinement reports update')
call require_close(new_shift(1), 2.0, 1.0e-6, 'topk=1 shift refinement damps x')
call require_close(new_shift(2), -2.0, 1.0e-6, 'topk=1 shift refinement damps y')
call require_close(tab%cand(1,1)%weight, 1.0, 1.0e-6, 'topk=1 shift refinement keeps unit weight')
call require_true(tab%hard_rank(1) == 1, 'topk=1 shift refinement keeps hard rank one')
call tab%apply_inpl_refinement(1, 1, 7, 0.125, 1.0, 0.1, old_inpl=old_inpl, updated=updated)
call require_true(updated, 'topk=1 in-plane refinement reports update')
call require_true(old_inpl == 20, 'topk=1 in-plane refinement reports old in-plane index')
call require_true(tab%cand(1,1)%inpl == 7, 'topk=1 in-plane refinement updates in-plane index')
call require_close(tab%cand(1,1)%weight, 1.0, 1.0e-6, 'topk=1 in-plane refinement keeps unit weight')
call require_true(tab%hard_rank(1) == 1, 'topk=1 in-plane refinement keeps hard rank one')

call tab%write_diag('unit-test')
call tab%kill
write(logfhandle,'(A)') 'simple_test_joint2D_candidate_table complete'

contains

    subroutine init_loc_tab( tab_in )
        type(ptcl_ref), intent(inout) :: tab_in(:,:)
        tab_in = ptcl_ref()
        call set_ref(tab_in(1,1), 101, 1, 10, 3.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(2,1), 101, 2, 20, 1.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(3,1), 101, 3,  5, 1.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(4,1), 101, 4,  0, -10.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(5,1), 101, 5, 15, 2.0, 1.5, -2.0, .true.)

        call set_ref(tab_in(1,2), 102, 1, 11, 1000000.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(2,2), 102, 2, 12, 1000001.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(3,2), 102, 3, 13, 1000002.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(4,2), 102, 4, 14, huge(1.0), 0.0, 0.0, .false.)

        call set_ref(tab_in(1,4), 104, 1, 21, 5.0, 0.0, 0.0, .false.)
        call set_ref(tab_in(2,4), 104, 2, 22, 4.0, 0.0, 0.0, .false.)
    end subroutine init_loc_tab

    subroutine init_base_shifts( shifts )
        real, intent(out) :: shifts(:,:)
        shifts = 0.
        shifts(:,1) = [10.0, 20.0]
        shifts(:,2) = [30.0, 40.0]
        shifts(:,3) = [50.0, 60.0]
        shifts(:,4) = [70.0, 80.0]
    end subroutine init_base_shifts

    subroutine set_ref( ref, pind, icls, inpl, dist, x, y, has_sh )
        type(ptcl_ref), intent(inout) :: ref
        integer,        intent(in)    :: pind, icls, inpl
        real,           intent(in)    :: dist, x, y
        logical,        intent(in)    :: has_sh
        ref%pind = pind
        ref%icls = icls
        ref%inpl = inpl
        ref%dist = dist
        ref%x = x
        ref%y = y
        ref%has_sh = has_sh
    end subroutine set_ref

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond ) THROW_HARD('simple_test_joint2D_candidate_table failed: '//trim(msg))
    end subroutine require_true

    subroutine require_close( got, expected, tol, msg )
        real,             intent(in) :: got, expected, tol
        character(len=*), intent(in) :: msg
        if( abs(got - expected) > tol )then
            write(logfhandle,'(A,1X,ES12.4,1X,A,1X,ES12.4)') 'got=', got, 'expected=', expected
            THROW_HARD('simple_test_joint2D_candidate_table failed: '//trim(msg))
        endif
    end subroutine require_close

end program simple_test_joint2D_candidate_table
