program simple_test_joint2D_distributed_parity
use simple_core_module_api
use simple_strategy2D_joint_sgd_candidates, only: joint2D_candidate_table, joint2D_candidate_part_fname
use simple_type_defs, only: ptcl_ref
implicit none

#include "simple_local_flags.inc"

type(ptcl_ref) :: loc_tab(4,5)
type(joint2D_candidate_table) :: global_tab, merged_tab, part1, part2, part_roundtrip
type(joint2D_candidate_table) :: hard_global, hard_part
type(joint2D_candidate_table) :: parts(2)
integer :: pinds(5), part1_pinds(3), part2_pinds(2)
real    :: shared_support(4), part_support(4), rejected_support(4)

pinds       = [11, 12, 13, 14, 15]
part1_pinds = [11, 13, 15]
part2_pinds = [12, 14]
call init_loc_tab(loc_tab)

call global_tab%build_from_loc_tab(loc_tab, 2, pinds=pinds)
call global_tab%apply_reliability(2, 1.0)
call require_true(all(global_tab%pinds == pinds), 'global table records exact particle order')
call require_true(global_tab%ncand(3) == 0, 'empty particle remains empty in global table')
call require_true(.not. global_tab%accepted(3), 'empty particle remains rejected in global table')

call global_tab%extract_by_pinds(part1_pinds, part1)
call global_tab%extract_by_pinds(part2_pinds, part2)
call require_true(all(part1%pinds == part1_pinds), 'part 1 keeps exact requested order')
call require_true(all(part2%pinds == part2_pinds), 'part 2 keeps exact requested order')
call require_true(part1%ncand(2) == 0, 'empty particle remains empty in part table')
call require_true(.not. part1%accepted(2), 'empty particle remains rejected in part table')

parts(1) = part1
parts(2) = part2
call merged_tab%merge_parts_by_pinds(parts, pinds)
call require_true(merged_tab%records_equal(global_tab, 0.0), 'partition merge is record-identical')
call require_true(merged_tab%checksum() == global_tab%checksum(), 'partition merge preserves checksum')

call del_file(joint2D_candidate_part_fname(1, 3))
call part1%write_part_table(1, 3)
call part_roundtrip%read_part_table(1, 3)
call require_true(part_roundtrip%records_equal(part1, 0.0), 'part table binary roundtrip is record-identical')
call require_true(part_roundtrip%checksum() == part1%checksum(), 'part table binary roundtrip preserves checksum')
call del_file(joint2D_candidate_part_fname(1, 3))

call accumulate_support(global_tab, shared_support)
call accumulate_support(part1, part_support)
call accumulate_support(part2, rejected_support)
part_support = part_support + rejected_support
call require_close(maxval(abs(part_support - shared_support)), 0.0, 1.0e-6,&
    &'sum of worker supports equals shared support')

call global_tab%apply_reliability(3, 1.0)
call accumulate_support(global_tab, rejected_support)
call require_close(sum(rejected_support), 0.0, 1.0e-6, 'rejected candidates contribute zero support')
call global_tab%apply_reliability(2, 1.0)

call hard_global%build_from_loc_tab(loc_tab, 1, pinds=pinds)
call hard_global%extract_by_pinds(part1_pinds, hard_part)
call require_true(hard_part%ncand(1) == 1, 'topk=1 part keeps one candidate')
call require_close(hard_part%cand(1,1)%weight, 1.0, 1.0e-6, 'topk=1 part candidate weight is one')
call require_true(hard_part%hard_rank(1) == 1, 'topk=1 part hard rank is one')
call require_true(hard_part%cand(1,1)%hard, 'topk=1 part hard flag is set')
call require_true(hard_part%ncand(2) == 0, 'topk=1 part preserves empty particle')

call global_tab%write_distributed_diag('unit-test global', 0, 2)
call part1%write_distributed_diag('unit-test part1', 1, 2)
call part2%write_distributed_diag('unit-test part2', 2, 2)

call hard_part%kill
call hard_global%kill
call part_roundtrip%kill
call part1%kill
call part2%kill
call parts(1)%kill
call parts(2)%kill
call merged_tab%kill
call global_tab%kill
write(logfhandle,'(A)') 'simple_test_joint2D_distributed_parity complete'

contains

    subroutine init_loc_tab( tab )
        type(ptcl_ref), intent(inout) :: tab(:,:)
        tab = ptcl_ref()
        call set_ref(tab(1,1), 11, 1, 10, 1.0)
        call set_ref(tab(2,1), 11, 2, 20, 2.0)
        call set_ref(tab(3,1), 11, 3, 30, 3.0)
        call set_ref(tab(2,2), 12, 2, 11, 0.5)
        call set_ref(tab(3,2), 12, 3, 21, 1.5)
        call set_ref(tab(1,4), 14, 1, 14, 0.25)
        call set_ref(tab(3,4), 14, 3, 34, 0.25)
        call set_ref(tab(4,4), 14, 4,  0, 0.10)
        call set_ref(tab(4,5), 15, 4, 44, 0.75)
        call set_ref(tab(2,5), 15, 2, 24, 1.25)
    end subroutine init_loc_tab

    subroutine set_ref( ref, pind, icls, inpl, dist )
        type(ptcl_ref), intent(inout) :: ref
        integer,        intent(in)    :: pind, icls, inpl
        real,           intent(in)    :: dist
        ref%pind = pind
        ref%icls = icls
        ref%inpl = inpl
        ref%dist = dist
    end subroutine set_ref

    subroutine accumulate_support( tab, support )
        type(joint2D_candidate_table), intent(in)  :: tab
        real,                          intent(out) :: support(:)
        integer :: iptcl, irank, icls
        support = 0.0
        do iptcl = 1, size(tab%ncand)
            if( .not. tab%accepted(iptcl) ) cycle
            do irank = 1, tab%ncand(iptcl)
                icls = tab%cand(irank,iptcl)%icls
                if( icls >= 1 .and. icls <= size(support) )then
                    support(icls) = support(icls) + tab%cand(irank,iptcl)%eff_weight
                endif
            end do
        end do
    end subroutine accumulate_support

    subroutine require_true( cond, msg )
        logical,          intent(in) :: cond
        character(len=*), intent(in) :: msg
        if( .not. cond ) THROW_HARD('simple_test_joint2D_distributed_parity failed: '//trim(msg))
    end subroutine require_true

    subroutine require_close( got, expected, tol, msg )
        real,             intent(in) :: got, expected, tol
        character(len=*), intent(in) :: msg
        if( abs(got - expected) > tol )then
            write(logfhandle,'(A,1X,ES12.4,1X,A,1X,ES12.4)') 'got=', got, 'expected=', expected
            THROW_HARD('simple_test_joint2D_distributed_parity failed: '//trim(msg))
        endif
    end subroutine require_close

end program simple_test_joint2D_distributed_parity
