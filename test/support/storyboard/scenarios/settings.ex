defmodule Minga.Test.Storyboard.Scenarios.Settings do
  @moduledoc "Registry entries for the `settings` journey."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `settings` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("settings.extensions.none",
        reach: "SPC h e l",
        recognize: &Model.empty_picker?(&1, ~r/extensions/i, ~r/^No extensions/),
        checks: [
          Check.new("no extensions says what they are for and points at the config", fn model ->
            assert_empty_state(model,
              title: "No extensions installed.",
              description: "Extensions add languages, tools and commands.",
              actions: [{"SPC f p", "Open your config"}]
            )
          end)
        ]
      )
    ]
  end
end
