# Dialyzer warnings to ignore.
#
# All 4 are opaque MapSet warnings from Board.State containing
# tool_declined: MapSet.new() as a struct default. Dialyzer considers
# constructing or passing a struct with an opaque field as an opaque
# violation. This is a known limitation; the code is correct.
[
  # Board.State.new/0 returns a struct containing MapSet.new()
  {"lib/minga/shell/board/state.ex", :contract_with_opaque},
  # Board.Persistence.restore_state/1 returns Board.State with MapSet default
  {"lib/minga/shell/board/persistence.ex", :contract_with_opaque},
  # Board.create_card/2 receives Board.State with opaque MapSet field
  {"lib/minga/shell/board.ex", :call_without_opaque},
  # emit/gui.ex constructs Board.State to encode a "dismissed" board message
  {"lib/minga/frontend/emit/gui.ex", :call_without_opaque}
]
