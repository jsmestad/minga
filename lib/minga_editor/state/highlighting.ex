defmodule MingaEditor.State.Highlighting do
  @moduledoc """
  Owns live syntax-highlight presentation caches.

  Parser identity, parse sequencing, registration, activity, and eviction belong to `Minga.Parser.Manager`. This struct contains only per-buffer presentation data and optional syntax palette overrides.
  """

  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Theme

  @type t :: %__MODULE__{
          highlights: %{pid() => Highlight.t()},
          syntax_overrides: %{pid() => Theme.syntax()}
        }

  defstruct highlights: %{}, syntax_overrides: %{}

  @doc "Replaces syntax overrides."
  @spec set_syntax_overrides(t(), %{pid() => Theme.syntax()}) :: t()
  def set_syntax_overrides(%__MODULE__{} = state, overrides) when is_map(overrides) do
    %{state | syntax_overrides: overrides}
  end

  @doc "Stores highlight data for a buffer."
  @spec put_highlight(t(), pid(), Highlight.t()) :: t()
  def put_highlight(%__MODULE__{} = state, pid, highlight) do
    %{state | highlights: Map.put(state.highlights, pid, highlight)}
  end

  @doc "Replaces the highlight map."
  @spec set_highlights(t(), %{pid() => Highlight.t()}) :: t()
  def set_highlights(%__MODULE__{} = state, highlights) when is_map(highlights) do
    %{state | highlights: highlights}
  end

  @doc """
  Rebuilds every buffer's highlight face registry from a new theme.

  Buffers with a stored syntax override keep their custom, theme-independent palette.
  """
  @spec retheme_all(t(), Theme.t()) :: t()
  def retheme_all(%__MODULE__{highlights: highlights, syntax_overrides: overrides} = state, theme) do
    rethemed =
      Map.new(highlights, fn {pid, highlight} ->
        if Map.has_key?(overrides, pid) do
          {pid, highlight}
        else
          {pid, Highlight.retheme(highlight, theme)}
        end
      end)

    %{state | highlights: rethemed}
  end

  @doc "Removes all highlight presentation state for a buffer."
  @spec remove_buffer(t(), pid()) :: t()
  def remove_buffer(%__MODULE__{} = state, buffer_pid) do
    %{
      state
      | highlights: Map.delete(state.highlights, buffer_pid),
        syntax_overrides: Map.delete(state.syntax_overrides, buffer_pid)
    }
  end
end
