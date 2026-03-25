defmodule Minga.Editor.State.Search do
  @moduledoc """
  Groups search-related fields from EditorState.

  Tracks the last search pattern and direction (for `n`/`N` repeat), and
  cached project-wide search results for the picker.
  """

  @type t :: %__MODULE__{
          last_pattern: String.t() | nil,
          last_direction: Minga.Search.direction(),
          project_results: [Minga.Project.ProjectSearch.match()]
        }

  defstruct last_pattern: nil,
            last_direction: :forward,
            project_results: []

  @doc "Records the last search pattern and direction."
  @spec record(t(), String.t(), Minga.Search.direction()) :: t()
  def record(%__MODULE__{} = s, pattern, direction) do
    %{s | last_pattern: pattern, last_direction: direction}
  end

  @doc "Records just the last search pattern (keeps existing direction)."
  @spec record_pattern(t(), String.t()) :: t()
  def record_pattern(%__MODULE__{} = s, pattern) do
    %{s | last_pattern: pattern}
  end
end
