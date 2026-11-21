defmodule MingaEditor.Renderer.SearchHighlight do
  @moduledoc """
  Search match computation, substitute preview, and pattern extraction.

  Match positions are computed here. Rendering is handled by the
  decoration system: search matches become highlight range decorations
  in `ContentHelpers.maybe_update_search_decorations/4`.
  """

  alias Minga.Command.Parser
  alias Minga.Editing.Search.Match
  alias Minga.Mode.SubstituteConfirmState
  alias Minga.Search.IndexGeneration
  alias Minga.Search.IndexOwner
  alias MingaEditor.Renderer.StaleSearchError
  alias MingaEditor.State, as: EditorState

  @typedoc "A search match with buffer position and length."
  @type search_match :: Match.t()

  @typedoc "Internal editor state."
  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()

  @doc "Applies a live substitute preview when the user is typing `:%s/pat/repl`."
  @spec maybe_substitute_preview(state(), [String.t()], non_neg_integer()) ::
          {[String.t()], [search_match()]}
  def maybe_substitute_preview(
        %{
          workspace: %{
            editing: %{mode: :command, mode_state: %Minga.Mode.CommandState{input: input}}
          }
        },
        lines,
        first_line
      ) do
    case Parser.substitute_preview(input) do
      {:preview_replacement, pattern, replacement, global?} ->
        substitute_preview_lines(lines, first_line, pattern, replacement, global?)

      _ ->
        {lines, []}
    end
  end

  def maybe_substitute_preview(_state, lines, _first_line), do: {lines, []}

  @doc "Returns whether temporary text replacements can change source layout."
  @spec substitute_preview?(state()) :: boolean()
  def substitute_preview?(state) do
    case substitute_input(state) do
      nil ->
        false

      input ->
        match?({:preview_replacement, _, _, _}, Parser.substitute_preview(input))
    end
  end

  @doc "Computes search matches for the visible line range."
  @spec search_matches_for_lines(state(), [String.t()], non_neg_integer()) :: [search_match()]
  def search_matches_for_lines(state, lines, first_line) do
    search_matches(state, lines, first_line, active_gui_generation(state))
  end

  @doc "Returns source-independent search and substitute inputs for resident composition."
  @spec composition_key(state()) :: tuple()
  def composition_key(state),
    do: {search_composition_key(state), substitute_input(state), current_confirm_match(state)}

  @spec search_matches(state(), [String.t()], non_neg_integer(), IndexGeneration.t() | nil) ::
          [search_match()]
  defp search_matches(_state, [], _first_line, _generation), do: []

  defp search_matches(_state, lines, first_line, %IndexGeneration{} = generation) do
    last_line = first_line + length(lines) - 1

    case IndexOwner.matches_in_range(generation, first_line, last_line) do
      {:ok, matches} -> matches
      :stale -> raise StaleSearchError, generation: generation
    end
  end

  defp search_matches(%{workspace: %{search: %{active: true}}}, _lines, _first_line, nil),
    do: []

  defp search_matches(state, lines, first_line, nil) do
    pattern = active_search_pattern(state)

    if is_binary(pattern) and pattern != "" do
      Minga.Editing.search_all_in_range(lines, pattern, first_line)
    else
      []
    end
  end

  @spec active_gui_generation(state()) :: IndexGeneration.t() | nil
  defp active_gui_generation(%{
         workspace: %{
           search: %{
             active: true,
             status: :ready,
             generation: %IndexGeneration{} = generation
           }
         }
       }),
       do: generation

  defp active_gui_generation(_state), do: nil

  @spec search_composition_key(state()) :: term()
  defp search_composition_key(%{
         workspace: %{search: %{active: true, query_revision: revision, status: status}}
       }),
       do: {:gui, revision, gui_index_state(status)}

  defp search_composition_key(state), do: {:classic, active_search_pattern(state)}

  @spec gui_index_state(atom()) :: :ready | :pending
  defp gui_index_state(:ready), do: :ready
  defp gui_index_state(_status), do: :pending

  @spec substitute_input(state()) :: String.t() | nil
  defp substitute_input(%{
         workspace: %{
           editing: %{mode: :command, mode_state: %Minga.Mode.CommandState{input: input}}
         }
       }),
       do: input

  defp substitute_input(_state), do: nil

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec substitute_preview_lines(
          [String.t()],
          non_neg_integer(),
          String.t(),
          String.t(),
          boolean()
        ) :: {[String.t()], [search_match()]}
  defp substitute_preview_lines(lines, first_line, pattern, replacement, global?) do
    {new_lines, {_next_line, reversed_matches}} =
      Enum.map_reduce(lines, {first_line, []}, fn line, {line_num, matches} ->
        {new_line, _count, spans} =
          Minga.Editing.substitute_line_preview(line, pattern, replacement, global?)

        matches =
          Enum.reduce(spans, matches, fn {col, len}, acc ->
            [Match.new(line_num, col, len) | acc]
          end)

        {new_line, {line_num + 1, matches}}
      end)

    {new_lines, Enum.reverse(reversed_matches)}
  end

  @spec active_search_pattern(state()) :: String.t() | nil
  defp active_search_pattern(%{
         workspace: %{
           editing: %{mode: :search, mode_state: %Minga.Mode.SearchState{input: input}}
         }
       })
       when input != "" do
    input
  end

  defp active_search_pattern(%{
         workspace: %{
           editing: %{mode: :command, mode_state: %Minga.Mode.CommandState{input: input}}
         }
       }) do
    case Parser.substitute_preview(input) do
      {:preview_pattern, pattern} -> pattern
      {:preview_replacement, pattern, _replacement, _global?} -> pattern
      nil -> nil
    end
  end

  defp active_search_pattern(%{
         workspace: %{
           editing: %{
             mode: :substitute_confirm,
             mode_state: %SubstituteConfirmState{pattern: pattern}
           }
         }
       })
       when pattern != "" do
    pattern
  end

  defp active_search_pattern(%{workspace: %{last_search_pattern: pattern}})
       when is_binary(pattern) and pattern != "" do
    pattern
  end

  defp active_search_pattern(_state), do: nil

  @doc "Returns the current match being confirmed, or nil."
  @spec current_confirm_match(state()) :: search_match() | nil
  def current_confirm_match(%{
        workspace: %{
          editing: %{
            mode: :substitute_confirm,
            mode_state: %SubstituteConfirmState{} = ms
          }
        }
      }) do
    SubstituteConfirmState.current_match(ms)
  end

  def current_confirm_match(_state), do: nil
end
