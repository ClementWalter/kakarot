from starkware.cairo.lang.compiler.scoped_name import ScopedName
from starkware.cairo.lang.vm.cairo_runner import CairoRunner
from starkware.cairo.lang.vm.memory_dict import MemoryDict


def run_program_entrypoint(program, entrypoint, program_input=None):
    runner = CairoRunner(
        program=program,
        layout="small",
        memory=MemoryDict(),
        proof_mode=False,
        allow_missing_builtins=False,
    )

    runner.initialize_segments()
    stack = []
    for builtin_name in runner.program.builtins:
        builtin_runner = runner.builtin_runners.get(f"{builtin_name}_builtin")
        if builtin_runner is None:
            assert runner.allow_missing_builtins, "Missing builtin."
            stack += [0]
        else:
            stack += builtin_runner.initial_stack()

    return_fp = runner.segments.add()
    end = runner.segments.add()
    stack = stack + [return_fp, end]

    runner.initialize_state(
        entrypoint=program.identifiers.get_by_full_name(
            ScopedName(path=["__main__", entrypoint])
        ).pc,
        stack=stack,
    )
    runner.initial_fp = runner.initial_ap = runner.execution_base + len(stack)
    runner.final_pc = end

    runner.initialize_vm(hint_locals={"program_input": program_input or {}})
    runner.run_until_pc(end)
    runner.original_steps = runner.vm.current_step
    runner.end_run(disable_trace_padding=False)
    runner.print_output()