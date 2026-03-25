defmodule Minga.UI.Picker.CommandSource do
  @moduledoc """
  Picker source for the command palette (M-x / SPC :).

  Lists all registered commands with their descriptions and keybinding
  annotations. Selecting a command executes it. Scopeable commands
  (those with a `scope` descriptor) open a secondary scope picker
  instead of executing immediately.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.UI.Picker.Item

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Command
  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Editor.PickerUI
  alias Minga.Keymap.Defaults
  alias Minga.UI.Picker.OptionScopeSource

  @impl true
  @spec title() :: String.t()
  def title, do: "Commands"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    keybind_map = build_keybind_map()

    try do
      CommandRegistry.all(CommandRegistry)
      |> Enum.map(fn cmd ->
        keybind = Map.get(keybind_map, cmd.name, "")
        annotation = if keybind != "", do: "SPC #{keybind}", else: ""

        %Item{
          id: cmd.name,
          label: "󰘳 #{cmd.name}: #{cmd.description}",
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
    case lookup_command(command_name) do
      %Command{scope: %{} = scope} = cmd ->
        open_scope_picker(state, cmd, scope)

      _ ->
        Map.update(state, :pending_command, command_name, fn _ -> command_name end)
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec lookup_command(atom()) :: Command.t() | nil
  defp lookup_command(name) do
    case CommandRegistry.lookup(CommandRegistry, name) do
      {:ok, cmd} -> cmd
      :error -> nil
    end
  catch
    :exit, _ -> nil
  end

  # Opens the scope picker for a scopeable command. Reads the current
  # value from the active buffer, computes the new value, and passes
  # both through the picker context.
  @spec open_scope_picker(term(), Command.t(), Command.scope()) :: term()
  defp open_scope_picker(state, cmd, %{option: option_name} = _scope) do
    buf = state.workspace.buffers.active

    current_value =
      if is_pid(buf) do
        BufferServer.get_option(buf, option_name)
      else
        nil
      end

    new_value = Command.compute_new_value(cmd, current_value)

    context = %{
      option_name: option_name,
      new_value: new_value,
      command_name: cmd.name,
      command_description: cmd.description
    }

    PickerUI.open(state, OptionScopeSource, context)
  end

  @spec build_keybind_map() :: %{atom() => String.t()}
  defp build_keybind_map do
    Defaults.all_bindings()
    |> Enum.into(%{}, fn {keys, command, _desc} ->
      key_str =
        Enum.map_join(keys, " ", fn {codepoint, _mods} ->
          <<codepoint::utf8>>
        end)

      {command, key_str}
    end)
  end
end
