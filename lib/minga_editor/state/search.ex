defmodule MingaEditor.State.Search do
  @moduledoc """
  Groups search-related fields from EditorState.

  Tracks the last search pattern and direction (for `n`/`N` repeat),
  cached project-wide search results for the picker, and the GUI search
  toolbar state (active, flags, replace mode).
  """

  @typedoc "GUI search toolbar state."
  @type gui_search :: %{
          active: boolean(),
          replace_mode: boolean(),
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean()
        }

  @type t :: %__MODULE__{
          last_pattern: String.t() | nil,
          last_direction: Minga.Editing.Search.direction(),
          project_results: [Minga.Project.ProjectSearch.match()],
          gui_search: gui_search() | nil
        }

  defstruct last_pattern: nil,
            last_direction: :forward,
            project_results: [],
            gui_search: nil

  @doc "Records the last search pattern and direction."
  @spec record(t(), String.t(), Minga.Editing.Search.direction()) :: t()
  def record(%__MODULE__{} = s, pattern, direction) do
    %{s | last_pattern: pattern, last_direction: direction}
  end

  @doc "Records just the last search pattern (keeps existing direction)."
  @spec record_pattern(t(), String.t()) :: t()
  def record_pattern(%__MODULE__{} = s, pattern) do
    %{s | last_pattern: pattern}
  end

  @doc "Sets just the last search direction."
  @spec set_last_direction(t(), Minga.Editing.Search.direction()) :: t()
  def set_last_direction(%__MODULE__{} = s, direction) do
    %{s | last_direction: direction}
  end

  @doc "Replaces the cached project search results."
  @spec set_project_results(t(), [Minga.Project.ProjectSearch.match()]) :: t()
  def set_project_results(%__MODULE__{} = s, results) when is_list(results) do
    %{s | project_results: results}
  end

  @doc "Activates the GUI search toolbar with the given flags."
  @spec activate_gui_search(t(), boolean(), boolean(), boolean()) :: t()
  def activate_gui_search(%__MODULE__{} = s, case_sensitive, whole_word, regex) do
    %{
      s
      | gui_search: %{
          active: true,
          replace_mode: false,
          case_sensitive: case_sensitive,
          whole_word: whole_word,
          regex: regex
        }
    }
  end

  @doc "Updates the GUI search toolbar flags."
  @spec update_gui_search_flags(t(), boolean(), boolean(), boolean()) :: t()
  def update_gui_search_flags(
        %__MODULE__{gui_search: %{} = gs} = s,
        case_sensitive,
        whole_word,
        regex
      ) do
    %{
      s
      | gui_search: %{gs | case_sensitive: case_sensitive, whole_word: whole_word, regex: regex}
    }
  end

  def update_gui_search_flags(%__MODULE__{} = s, case_sensitive, whole_word, regex) do
    activate_gui_search(s, case_sensitive, whole_word, regex)
  end

  @doc "Sets replace mode on the GUI search toolbar."
  @spec set_gui_replace_mode(t(), boolean()) :: t()
  def set_gui_replace_mode(%__MODULE__{gui_search: %{} = gs} = s, replace_mode) do
    %{s | gui_search: %{gs | replace_mode: replace_mode}}
  end

  def set_gui_replace_mode(%__MODULE__{} = s, _replace_mode), do: s

  @doc "Dismisses the GUI search toolbar."
  @spec dismiss_gui_search(t()) :: t()
  def dismiss_gui_search(%__MODULE__{} = s) do
    %{s | gui_search: nil}
  end

  @doc "Returns whether the GUI search toolbar is active."
  @spec gui_search_active?(t()) :: boolean()
  def gui_search_active?(%__MODULE__{gui_search: %{active: true}}), do: true
  def gui_search_active?(%__MODULE__{}), do: false
end
