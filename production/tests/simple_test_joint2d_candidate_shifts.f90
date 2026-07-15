program simple_test_joint2d_candidate_shifts
use simple_core_module_api
use simple_type_defs, only: ptcl_ref
use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table
implicit none

character(len=*), parameter :: fname = 'joint2d_candidate_shift_roundtrip.dat'
type(joint2D_candidate_table) :: candidates, restored
type(ptcl_ref) :: loc_tab(2,1)
real :: seed_shifts(2,1), base_shifts(2,1), old_shift(2), new_shift(2), step
logical :: seed_has_sh(1), updated
integer :: old_inpl

loc_tab(1,1)%pind   = 1
loc_tab(1,1)%icls   = 1
loc_tab(1,1)%inpl   = 1
loc_tab(1,1)%dist   = 2.0
loc_tab(1,1)%x      = 0.5
loc_tab(1,1)%y      = -0.25
loc_tab(1,1)%has_sh = .true.

loc_tab(2,1)%pind   = 1
loc_tab(2,1)%icls   = 2
loc_tab(2,1)%inpl   = 2
loc_tab(2,1)%dist   = 3.0
loc_tab(2,1)%has_sh = .false.

call candidates%build_from_loc_tab(loc_tab, 2, pinds=[1])
seed_shifts(:,1) = [1.0, 0.0]
seed_has_sh(1)   = .true.
call candidates%materialize_seed_shifts(seed_shifts, seed_has_sh, .true., 4)
if( .not. candidates%cand(2,1)%has_sh ) error stop 'seed shift was not materialized'
if( abs(candidates%cand(2,1)%x**2 + candidates%cand(2,1)%y**2 - 1.0) > 1.0e-5 )&
    &error stop 'materialized seed shift changed magnitude'

base_shifts(:,1) = [4.0, 5.0]
call candidates%set_base_shifts(base_shifts)
call candidates%write_table(fname)
call restored%read_table(fname)
if( .not. candidates%records_equal(restored, 1.0e-6) ) error stop 'candidate shift provenance did not round-trip'

call restored%apply_inpl_refinement(1, 1, 2, 2.5, old_inpl=old_inpl, updated=updated,&
    &refined_shift=[0.1,0.2])
if( updated ) error stop 'non-improving in-plane proposal was applied'
if( restored%cand(1,1)%inpl /= 1 .or. abs(restored%cand(1,1)%dist - 2.0) > 1.0e-6 )&
    &error stop 'non-improving in-plane proposal changed the candidate'

call restored%apply_inpl_refinement(1, 1, 2, 1.0, old_inpl=old_inpl, updated=updated,&
    &refined_shift=[0.1,0.2])
if( .not. updated ) error stop 'improving in-plane proposal was not applied'
if( old_inpl /= 1 .or. restored%cand(1,1)%inpl /= 2 ) error stop 'in-plane update bookkeeping failed'
if( maxval(abs([restored%cand(1,1)%x,restored%cand(1,1)%y] - [0.1,0.2])) > 1.0e-6 )&
    &error stop 'in-plane update did not preserve its effective shift'

call restored%apply_shift_refinement(1, 1, [1.0,1.0], 1.5, 0.25,&
    &old_shift=old_shift, new_shift=new_shift, step_norm=step, updated=updated)
if( updated ) error stop 'non-improving shift proposal was applied'
if( maxval(abs(new_shift - [0.1,0.2])) > 1.0e-6 ) error stop 'rejected shift proposal changed the candidate'

call restored%apply_shift_refinement(1, 1, [0.5,0.6], 0.5, 0.25,&
    &old_shift=old_shift, new_shift=new_shift, step_norm=step, updated=updated)
if( .not. updated ) error stop 'improving shift proposal was not applied'
if( restored%cand(1,1)%dist >= 1.0 ) error stop 'improving shift proposal did not lower the distance'

call del_file(fname)
call candidates%kill
call restored%kill
write(*,'(A)') 'joint2D candidate shift regression: PASS'
end program simple_test_joint2d_candidate_shifts
