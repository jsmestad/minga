defmodule MingaEditor.Shell.Traditional.TabBarRenderer do
  @moduledoc """
  Tab bar click-region contract.

  The tab bar renders natively on the semantic frontends (the `tab_bar` UI
  model, encoded by `Minga.Frontend.Adapter.GUI`). This module survives only as
  the home of the `click_region` type that the mouse hit-test layer
  (`MingaEditor.Mouse`) and the chrome click-region threading
  (`RenderPipeline.Chrome`/`Shell.Traditional.State`) reference for tab bar
  hit-testing.

  The cell-grid painter (`render/5`, `render_chrome_state/5`, and the segment,
  overflow, and close-button draw helpers) was removed in #2311 — nothing
  consumed the cell draws.
  """

  @typedoc "A clickable tab bar command."
  @type tab_command ::
          atom() | {:workspace_goto, non_neg_integer()} | {:tab_goto_id, pos_integer()}

  @typedoc "A clickable region: column range mapping to a command."
  @type click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(), command :: tab_command()}
          | {row :: non_neg_integer(), col_start :: non_neg_integer(),
             col_end :: non_neg_integer(), command :: tab_command()}
end
