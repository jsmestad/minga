defmodule Minga.Shell.Traditional.Chrome do
  @moduledoc """
  Chrome building for the Traditional shell.

  The Traditional shell's chrome includes: tab bar, modeline/status bar,
  file tree sidebar, agent panel, which-key popup, completion menu,
  signature help, and hover popups.

  Delegates to `Minga.Editor.RenderPipeline.Chrome` which contains the
  actual chrome building logic. As the shell independence refactor
  progresses, the implementation will move here.
  """

  defdelegate build_chrome(state, layout, scrolls, cursor_info),
    to: Minga.Editor.RenderPipeline.Chrome
end
