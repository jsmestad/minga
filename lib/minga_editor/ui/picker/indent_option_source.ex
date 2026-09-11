defmodule MingaEditor.UI.Picker.IndentOptionSource do
  @moduledoc """
  Picker source for indentation settings.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.Commands.Help
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.OptionSource

  @indent_options [:indent_with, :tab_width]

  @impl true
  @spec title() :: String.t()
  def title, do: "Indent Settings"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{} = context) do
    OptionSource.builtin_items(context, @indent_options)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: name}, state) when name in @indent_options do
    Help.describe_option(state, name)
  end

  def on_select(_item, state), do: state
end
