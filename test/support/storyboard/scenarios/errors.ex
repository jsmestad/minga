defmodule Minga.Test.Storyboard.Scenarios.Errors do
  @moduledoc "Registry entries for the `errors` journey: crash notices and persistent problems."

  alias Minga.Test.Storyboard.Entry

  @doc "Every `errors` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending(
        "errors.crash_reconnect",
        4027,
        "no surface ticket names the crash notice yet; the epic owns it"
      ),
      Entry.pending(
        "errors.lsp_failed",
        4059,
        "a failed language server is a persistent modeline problem"
      ),
      Entry.pending(
        "errors.config_error",
        4059,
        "a config that did not load is a persistent modeline problem"
      )
    ]
  end
end
