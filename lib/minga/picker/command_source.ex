defmodule Minga.Picker.CommandSource do
  @moduledoc """
  Picker source for the command palette (M-x / SPC :).

  Lists all registered commands with their descriptions and keybinding
  annotations. Selecting a command executes it.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Keymap.Defaults

  require Logger

  @impl true
  @spec title() :: String.t()
  def title, do: "Commands"

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    # Build a map of command_name → keybinding string for annotations
    keybind_map = build_keybind_map()

    try do
      CommandRegistry.all(CommandRegistry)
      |> Enum.map(fn cmd ->
        keybind = Map.get(keybind_map, cmd.name, "")
        annotation = if keybind != "", do: "SPC #{keybind}", else: ""
        {cmd.name, "#{cmd.name}: #{cmd.description}", annotation}
      end)
      |> Enum.sort_by(fn {_id, label, _desc} -> label end)
    catch
      :exit, _ ->
        Logger.warning("Command registry not available")
        []
    end
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({command_name, _label, _desc}, state) do
    # Execute the command by adding it to pending_commands, which the
    # editor will pick up and execute through its normal command dispatch.
    Map.update(state, :pending_command, command_name, fn _ -> command_name end)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  # Build a map of command_name → key sequence string from leader defaults.
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
