defmodule Minga.Test.Storyboard.Scenarios.Terminal do
  @moduledoc "Registry entries for the `terminal` journey: the built-in terminal and Minga's shell."

  alias Minga.Test.Storyboard.Entry

  @doc "Every `terminal` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending("terminal.drawer", 4060, "a shell in a terminal buffer"),
      Entry.pending("terminal.minga_shell", 4061, "Minga's shell work is visible"),
      Entry.pending("terminal.capabilities", 4062, "the :checkhealth terminal capability report"),
      Entry.pending("terminal.drawer.normal", 4060, "Normal mode in the terminal drawer"),
      Entry.pending(
        "terminal.failed_block.menu",
        4061,
        "commands become blocks with an act menu"
      ),
      Entry.pending("terminal.minga_shell.approval", 4061, "approving Minga's shell command"),
      Entry.pending("terminal.window", 4060, "a terminal in the current window"),
      Entry.pending("terminal.exited", 4060, "what is left after the shell exits"),
      Entry.pending("terminal.plain", 4060, "a terminal without shell integration")
    ]
  end
end
