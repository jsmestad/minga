defmodule MingaEditor.UI.Picker.CommandHelpSource do
  @moduledoc """
  Picker source for describing commands.

  Lists all registered commands with descriptions and keybinding annotations.
  Selecting a command opens a `*Help*` buffer with detailed information
  about the command rather than executing it.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Command
  alias MingaEditor.Commands.Help
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Describe Command"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    keybind_map = Help.build_reverse_keybind_map()

    try do
      Command.all_commands()
      |> Enum.map(fn cmd ->
        bindings = Map.get(keybind_map, cmd.name, [])
        annotation = Enum.join(bindings, ", ")

        %Item{
          id: cmd.name,
          label: "#{cmd.name}: #{cmd.description}",
          annotation: annotation
        }
      end)
      |> Enum.sort_by(& &1.label)
    catch
      :exit, _ ->
        Minga.Log.warning(:editor, "Command registry not available")
        []
    end
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: command_name}, state) do
    Help.execute(state, {:describe_command_named, Atom.to_string(command_name)})
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
