# Add a motion

Keep cursor movement pure so normal-mode and operator-pending clients can use the same behavior without starting an Editor process.

1. Add the implementation to the focused `Minga.Editing.Motion.*` module under `lib/minga/editing/motion/`, such as `Minga.Editing.Motion.Word` or `Minga.Editing.Motion.Line`.
2. Add a `defdelegate` in `Minga.Editing.Motion`, the entry point for motions.
3. Add a `defdelegate` in `Minga.Editing`, the entry point for the editing group, so callers can use the new motion through that API.
4. Register the motion in `Minga.Mode.Normal` and `Minga.Mode.OperatorPending` for the modes it supports.
5. Test against known buffer content, including empty text, boundaries, and Unicode. Use direct `Document` values for movement and FSM tests for emitted commands and transitions.

Use `test/minga/editing/motion/word_test.exs` as the pure-function pattern. Add cases to the owning motion test, then verify the mode contracts:

```bash
mix test.debug test/minga/editing/motion/word_test.exs test/minga/mode/normal_test.exs test/minga/mode/operator_pending_test.exs
```

Replace the word test path with the test for the motion you changed.
