# Add a text object

A text object describes the range an operator should edit. Keep range selection pure and let operator-pending mode choose when to use it.

1. Add the implementation in `lib/minga/editing/text_object.ex` with `@spec`.
2. Add a `defdelegate` in `Minga.Editing` so callers can use the text object through the editing entry point.
3. Register it in `Minga.Mode.OperatorPending`.
4. Test the selected range with the cursor outside delimiters, nested delimiters, empty content, and Unicode. Test the operator-pending mapping separately from the range algorithm.

Run the behavior and FSM contracts from the repository root:

```bash
mix test.debug test/minga/editing/text_object_test.exs test/minga/mode/operator_pending_test.exs
```
