defmodule Minga.Test.Storyboard.Scenarios.Settings do
  @moduledoc "Registry entries for the `settings` journey."

  alias Minga.Test.Storyboard.Entry

  @doc "Every `settings` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending("settings.extensions.none", 4058, "no extensions points somewhere")
    ]
  end
end
