defmodule MingaEditor.UI.Picker.AproposSource do
  @moduledoc """
  Picker source for `SPC h a`, apropos: one search across commands and options.

  Doom's apropos searches every symbol at once. Minga's searches the two things a user configures and runs, commands and options, grouped under a header for each. Picking a row opens its `*Help*` page, the same page `SPC h c` and `SPC h v` open.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.CommandHelpSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.OptionSource

  @impl true
  @spec title() :: String.t()
  def title, do: "Apropos"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = context) do
    commands = Enum.map(CommandHelpSource.candidates(context), &tag(&1, :command, "Commands"))
    options = Enum.map(OptionSource.candidates(context), &tag(&1, :option, "Options"))
    commands ++ options
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:command, id}} = item, state),
    do: CommandHelpSource.on_select(%{item | id: id}, state)

  def on_select(%Item{id: {:option, id}} = item, state),
    do: OptionSource.on_select(%{item | id: id}, state)

  def on_select(_item, state), do: state

  @spec tag(Item.t(), :command | :option, String.t()) :: Item.t()
  defp tag(%Item{id: id} = item, kind, group), do: %{item | id: {kind, id}, group: group}
end
