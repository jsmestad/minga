defmodule Minga.Editor.MinibufferData do
  @moduledoc """
  Structured minibuffer data for the GUI frontend.

  Extracts the current minibuffer state (mode, prompt, input, context,
  completion candidates) from editor state for encoding as the `0x7F
  gui_minibuffer` protocol opcode.

  The TUI continues to render the cell-grid minibuffer via
  `Minga.Editor.Renderer.Minibuffer`. This module serves the native
  SwiftUI minibuffer only.
  """

  alias Minga.Command
  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Editor.State, as: EditorState
  alias Minga.Keymap.Defaults
  alias Minga.UI.WhichKey

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A completion candidate for the minibuffer."
  @type candidate :: %{
          label: String.t(),
          description: String.t(),
          match_score: non_neg_integer(),
          match_positions: [non_neg_integer()],
          annotation: String.t()
        }

  @typedoc "Structured minibuffer data for GUI encoding."
  @type t :: %__MODULE__{
          visible: boolean(),
          mode: non_neg_integer(),
          cursor_pos: non_neg_integer(),
          prompt: String.t(),
          input: String.t(),
          context: String.t(),
          selected_index: non_neg_integer(),
          candidates: [candidate()],
          total_candidates: non_neg_integer()
        }

  @enforce_keys [:visible]
  defstruct visible: false,
            mode: 0,
            cursor_pos: 0xFFFF,
            prompt: "",
            input: "",
            context: "",
            selected_index: 0,
            candidates: [],
            total_candidates: 0

  # Mode constants matching the protocol spec
  @mode_command 0
  @mode_search_forward 1
  @mode_search_backward 2
  @mode_search_prompt 3
  @mode_eval 4
  @mode_substitute_confirm 5
  @mode_extension_confirm 6
  @mode_describe_key 7

  # Maximum candidates to send (keep the list manageable)
  @max_candidates 15

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Clamps a candidate index to the valid range for a candidate list.

  Wraps around in both directions so arrow navigation cycles through
  candidates. Returns 0 for empty lists.
  """
  @spec clamp_index(integer(), non_neg_integer()) :: non_neg_integer()
  def clamp_index(_index, 0), do: 0

  def clamp_index(index, count) when count > 0 do
    rem(rem(index, count) + count, count)
  end

  @doc """
  Extracts structured minibuffer data from the current editor state.

  Returns a `t()` struct ready for protocol encoding via
  `Minga.Frontend.Protocol.GUI.encode_gui_minibuffer/1`.
  """
  @spec from_state(EditorState.t()) :: t()

  def from_state(%{workspace: %{vim: %{mode: :command, mode_state: ms}}}) do
    input = ms.input
    {candidates, total} = complete_ex_command(input)
    raw_index = ms.candidate_index
    selected = clamp_index(raw_index, length(candidates))

    %__MODULE__{
      visible: true,
      mode: @mode_command,
      cursor_pos: String.length(input),
      prompt: ":",
      input: input,
      context: "",
      selected_index: selected,
      candidates: candidates,
      total_candidates: total
    }
  end

  def from_state(%{workspace: %{vim: %{mode: :search, mode_state: ms}}}) do
    {mode, prefix} = search_mode_and_prefix(ms.direction)
    context = format_search_context(ms)

    %__MODULE__{
      visible: true,
      mode: mode,
      cursor_pos: String.length(ms.input),
      prompt: prefix,
      input: ms.input,
      context: context,
      selected_index: 0,
      candidates: []
    }
  end

  def from_state(%{workspace: %{vim: %{mode: :search_prompt, mode_state: ms}}}) do
    %__MODULE__{
      visible: true,
      mode: @mode_search_prompt,
      cursor_pos: String.length(ms.input),
      prompt: "Search: ",
      input: ms.input,
      context: "",
      selected_index: 0,
      candidates: []
    }
  end

  def from_state(%{workspace: %{vim: %{mode: :eval, mode_state: ms}}}) do
    %__MODULE__{
      visible: true,
      mode: @mode_eval,
      cursor_pos: String.length(ms.input),
      prompt: "Eval: ",
      input: ms.input,
      context: "",
      selected_index: 0,
      candidates: []
    }
  end

  def from_state(%{workspace: %{vim: %{mode: :substitute_confirm, mode_state: ms}}}) do
    current = ms.current + 1
    total = length(ms.matches)

    %__MODULE__{
      visible: true,
      mode: @mode_substitute_confirm,
      cursor_pos: 0xFFFF,
      prompt: "replace with #{ms.replacement}?",
      input: "",
      context: "y/n/a/q (#{current} of #{total})",
      selected_index: 0,
      candidates: []
    }
  end

  def from_state(%{workspace: %{vim: %{mode: :extension_confirm, mode_state: ms}}}) do
    prompt = Minga.Mode.display(:extension_confirm, ms)

    %__MODULE__{
      visible: true,
      mode: @mode_extension_confirm,
      cursor_pos: 0xFFFF,
      prompt: prompt,
      input: "",
      context: "",
      selected_index: 0,
      candidates: []
    }
  end

  def from_state(%{
        workspace: %{
          vim: %{
            mode: :normal,
            mode_state: %{pending_describe_key: true, describe_key_keys: keys}
          }
        }
      }) do
    accumulated = keys |> Enum.reverse() |> Enum.join(" ")

    context =
      case keys do
        [] -> ""
        _ -> accumulated <> " …"
      end

    %__MODULE__{
      visible: true,
      mode: @mode_describe_key,
      cursor_pos: 0xFFFF,
      prompt: "Press key to describe:",
      input: "",
      context: context,
      selected_index: 0,
      candidates: []
    }
  end

  # All other modes: minibuffer hidden
  def from_state(_state) do
    %__MODULE__{visible: false}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec search_mode_and_prefix(:forward | :backward) ::
          {non_neg_integer(), String.t()}
  defp search_mode_and_prefix(:forward), do: {@mode_search_forward, "/"}
  defp search_mode_and_prefix(:backward), do: {@mode_search_backward, "?"}

  @spec format_search_context(map()) :: String.t()
  defp format_search_context(ms) do
    case Map.get(ms, :match_count) do
      nil -> ""
      0 -> "no matches"
      count -> "#{Map.get(ms, :current_match, 0) + 1} of #{count}"
    end
  end

  @doc """
  Generates completion candidates for an ex command input string.

  Queries the command registry and fuzzy-matches against the input.
  Returns up to `@max_candidates` results sorted by match quality.
  """
  @spec complete_ex_command(String.t()) :: {[candidate()], non_neg_integer()}
  def complete_ex_command(""), do: popular_commands()

  def complete_ex_command(input) do
    input_lower = String.downcase(input)
    keybind_map = build_keybind_map()

    matched =
      CommandRegistry.all(CommandRegistry)
      |> Enum.map(fn %Command{} = cmd ->
        name = to_string(cmd.name)
        score = fuzzy_score(name, input_lower)
        {cmd, name, score}
      end)
      |> Enum.filter(fn {_cmd, _name, score} -> score > 0 end)
      |> Enum.sort_by(fn {_cmd, _name, score} -> score end, :desc)

    total = length(matched)

    candidates =
      matched
      |> Enum.take(@max_candidates)
      |> Enum.map(fn {cmd, name, score} ->
        %{
          label: name,
          description: cmd.description || "",
          match_score: min(score, 255),
          match_positions: find_match_positions(name, input_lower),
          annotation: Map.get(keybind_map, cmd.name, "")
        }
      end)

    {candidates, total}
  end

  # When input is empty, show commonly used commands
  @spec popular_commands() :: {[candidate()], non_neg_integer()}
  defp popular_commands do
    popular = ~w(write quit edit save-buffer find-file split vsplit set help)a
    keybind_map = build_keybind_map()

    all = CommandRegistry.all(CommandRegistry)
    total = length(all)

    popular_cmds =
      Enum.filter(all, fn cmd -> cmd.name in popular end)
      |> Enum.sort_by(fn cmd -> Enum.find_index(popular, &(&1 == cmd.name)) || 999 end)

    remaining =
      all
      |> Enum.reject(fn cmd -> cmd.name in popular end)
      |> Enum.sort_by(fn cmd -> to_string(cmd.name) end)
      |> Enum.take(@max_candidates - length(popular_cmds))

    candidates =
      (popular_cmds ++ remaining)
      |> Enum.take(@max_candidates)
      |> Enum.map(fn cmd ->
        %{
          label: to_string(cmd.name),
          description: cmd.description || "",
          match_score: 100,
          match_positions: [],
          annotation: Map.get(keybind_map, cmd.name, "")
        }
      end)

    {candidates, total}
  end

  # Simple fuzzy scoring: prefix match gets highest score, then substring,
  # then character-order match. Returns 0 for no match.
  @spec fuzzy_score(String.t(), String.t()) :: non_neg_integer()
  defp fuzzy_score(name, query) do
    name_lower = String.downcase(name)
    length_penalty = String.length(name)
    score_match(name_lower, query, length_penalty)
  end

  @spec score_match(String.t(), String.t(), non_neg_integer()) :: integer()
  defp score_match(same, same, _len), do: 200

  defp score_match(name_lower, query, len) do
    do_score_match(name_lower, query, len)
  end

  @spec do_score_match(String.t(), String.t(), non_neg_integer()) :: integer()
  defp do_score_match(name_lower, query, len) do
    if String.starts_with?(name_lower, query) do
      150 + (100 - len)
    else
      do_score_substring(name_lower, query, len)
    end
  end

  @spec do_score_substring(String.t(), String.t(), non_neg_integer()) :: integer()
  defp do_score_substring(name_lower, query, len) do
    if String.contains?(name_lower, query) do
      100 + (100 - len)
    else
      do_score_chars(name_lower, query, len)
    end
  end

  @spec do_score_chars(String.t(), String.t(), non_neg_integer()) :: integer()
  defp do_score_chars(name_lower, query, len) do
    if chars_in_order?(name_lower, query) do
      50 + (100 - len)
    else
      0
    end
  end

  # Finds the character indices in `name` that match `query` characters
  # in order. Used for highlighting matched characters in the GUI.
  # Returns indices as 0-based grapheme positions.
  # Builds a map from command name atoms to human-readable keybinding strings.
  # Uses WhichKey.format_key for proper display (SPC, C-s, etc.).
  @spec build_keybind_map() :: %{atom() => String.t()}
  defp build_keybind_map do
    Defaults.all_bindings()
    |> Enum.into(%{}, fn {keys, command, _desc} ->
      key_str = Enum.map_join(keys, " ", &WhichKey.format_key/1)
      {command, key_str}
    end)
  end

  @spec find_match_positions(String.t(), String.t()) :: [non_neg_integer()]
  defp find_match_positions(name, query) do
    name_lower = String.downcase(name)
    name_chars = String.graphemes(name_lower)
    query_chars = String.graphemes(query)
    do_find_positions(name_chars, query_chars, 0, [])
  end

  @spec do_find_positions([String.t()], [String.t()], non_neg_integer(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp do_find_positions(_name, [], _idx, acc), do: Enum.reverse(acc)
  defp do_find_positions([], _query, _idx, acc), do: Enum.reverse(acc)

  defp do_find_positions([c | name_rest], [c | query_rest], idx, acc),
    do: do_find_positions(name_rest, query_rest, idx + 1, [idx | acc])

  defp do_find_positions([_ | name_rest], query, idx, acc),
    do: do_find_positions(name_rest, query, idx + 1, acc)

  @spec chars_in_order?(String.t(), String.t()) :: boolean()
  defp chars_in_order?(name, query) do
    name_chars = String.graphemes(name)
    query_chars = String.graphemes(query)
    do_chars_in_order?(name_chars, query_chars)
  end

  @spec do_chars_in_order?([String.t()], [String.t()]) :: boolean()
  defp do_chars_in_order?(_name, []), do: true
  defp do_chars_in_order?([], _query), do: false

  defp do_chars_in_order?([c | name_rest], [c | query_rest]),
    do: do_chars_in_order?(name_rest, query_rest)

  defp do_chars_in_order?([_ | name_rest], query),
    do: do_chars_in_order?(name_rest, query)
end
