defmodule MingaEditor.State.Highlighting do
  @moduledoc """
  Owns live syntax-highlight presentation caches.

  Parser identity, parse sequencing, registration, activity, and eviction belong to `Minga.Parser.Manager`. This struct contains only per-buffer presentation data and optional syntax palette overrides.
  """

  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Theme

  @type t :: %__MODULE__{
          highlights: %{pid() => Highlight.t()},
          syntax_overrides: %{pid() => Theme.syntax()},
          revisions: %{pid() => reference()}
        }

  defstruct highlights: %{}, syntax_overrides: %{}, revisions: %{}

  @doc "Replaces syntax overrides."
  @spec set_syntax_overrides(t(), %{pid() => Theme.syntax()}) :: t()
  def set_syntax_overrides(%__MODULE__{} = state, overrides) when is_map(overrides) do
    %{state | syntax_overrides: overrides}
  end

  @doc "Stores highlight data for a buffer."
  @spec put_highlight(t(), pid(), Highlight.t()) :: t()
  def put_highlight(%__MODULE__{} = state, pid, highlight) do
    %{
      state
      | highlights: Map.put(state.highlights, pid, highlight),
        revisions: Map.put(state.revisions, pid, revision_for(state, pid, highlight))
    }
  end

  @doc "Replaces the highlight map."
  @spec set_highlights(t(), %{pid() => Highlight.t()}) :: t()
  def set_highlights(%__MODULE__{} = state, highlights) when is_map(highlights) do
    %{
      state
      | highlights: highlights,
        revisions:
          Map.new(highlights, fn {pid, highlight} ->
            {pid, revision_for(state, pid, highlight)}
          end)
    }
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

    %{
      state
      | highlights: rethemed,
        revisions:
          Map.new(rethemed, fn {pid, highlight} -> {pid, revision_for(state, pid, highlight)} end)
    }
  end

  @doc "Removes all highlight presentation state for a buffer."
  @spec remove_buffer(t(), pid()) :: t()
  def remove_buffer(%__MODULE__{} = state, buffer_pid) do
    %{
      state
      | highlights: Map.delete(state.highlights, buffer_pid),
        syntax_overrides: Map.delete(state.syntax_overrides, buffer_pid),
        revisions: Map.delete(state.revisions, buffer_pid)
    }
  end

  @doc "Restores the highlight payload of a render snapshot without changing its source revisions."
  @spec restore_render_payload(t(), %{pid() => Highlight.t()}) :: t()
  def restore_render_payload(%__MODULE__{} = state, highlights) when is_map(highlights),
    do: %{state | highlights: highlights}

  @spec revision_for(t(), pid(), Highlight.t()) :: reference()
  defp revision_for(%__MODULE__{highlights: highlights, revisions: revisions}, buffer, highlight) do
    case Map.fetch(highlights, buffer) do
      {:ok, ^highlight} -> Map.fetch!(revisions, buffer)
      _changed -> make_ref()
    end
  end
end
