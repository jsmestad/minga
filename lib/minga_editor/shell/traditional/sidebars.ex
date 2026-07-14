defmodule MingaEditor.Shell.Traditional.Sidebars do
  @moduledoc """
  Pure aggregate for Traditional sidebar selection and built-in surfaces.

  The selected sidebar, Git status panel pair, and Observatory lifecycle are
  kept together so opening, closing, and replacing one built-in surface cannot
  leave an unrelated stale selection behind.
  """

  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.GitStatus.TUIState
  alias MingaEditor.Shell.Traditional.Observatory

  @type git_status_tui_state :: TUIState.t()
  @type t :: %__MODULE__{
          active_id: String.t() | nil,
          git_status_panel: GitStatusPanel.t() | nil,
          git_status_tui_state: git_status_tui_state() | nil,
          observatory: Observatory.t()
        }

  defstruct active_id: nil,
            git_status_panel: nil,
            git_status_tui_state: nil,
            observatory: %Observatory{}

  @doc "Returns the selected native sidebar id."
  @spec active_id(t()) :: String.t() | nil
  def active_id(%__MODULE__{active_id: id}), do: id

  @doc "Selects a visible sidebar, or clears selection with nil."
  @spec select(t(), String.t() | nil) :: t()
  def select(%__MODULE__{} = sidebars, id) when is_binary(id) or is_nil(id),
    do: %{sidebars | active_id: id}

  @doc "Returns the Git status panel."
  @spec git_status_panel(t()) :: GitStatusPanel.t() | nil
  def git_status_panel(%__MODULE__{git_status_panel: panel}), do: panel

  @doc "Returns the TUI-specific Git status view state."
  @spec git_status_tui_state(t()) :: git_status_tui_state() | nil
  def git_status_tui_state(%__MODULE__{git_status_tui_state: state}), do: state

  @doc "Replaces the Git status panel while retaining its TUI view state."
  @spec replace_git_status(t(), GitStatusPanel.t() | nil) :: t()
  def replace_git_status(%__MODULE__{} = sidebars, nil),
    do: %{sidebars | git_status_panel: nil}

  def replace_git_status(%__MODULE__{} = sidebars, %GitStatusPanel{} = panel),
    do: %{sidebars | git_status_panel: panel}

  @doc "Replaces the TUI-specific Git status view state."
  @spec replace_git_status_tui(t(), git_status_tui_state() | nil) :: t()
  def replace_git_status_tui(%__MODULE__{} = sidebars, nil),
    do: %{sidebars | git_status_tui_state: nil}

  def replace_git_status_tui(%__MODULE__{} = sidebars, %TUIState{} = state),
    do: %{sidebars | git_status_tui_state: state}

  @doc "Closes Git status and clears both shared and TUI-specific state."
  @spec close_git_status(t()) :: t()
  def close_git_status(%__MODULE__{} = sidebars) do
    active_id = if sidebars.active_id == "git_status", do: nil, else: sidebars.active_id

    %{
      sidebars
      | active_id: active_id,
        git_status_panel: nil,
        git_status_tui_state: nil
    }
  end

  @doc "Returns the Observatory lifecycle value."
  @spec observatory(t()) :: Observatory.t()
  def observatory(%__MODULE__{observatory: observatory}), do: observatory

  @doc "Opens and selects the Observatory surface."
  @spec open_observatory(t(), Observatory.timer() | nil) :: t()
  def open_observatory(%__MODULE__{} = sidebars, timer) do
    %{
      sidebars
      | active_id: "observatory",
        observatory: Observatory.open(sidebars.observatory, timer)
    }
  end

  @doc "Closes Observatory and clears its selection when selected."
  @spec close_observatory(t()) :: t()
  def close_observatory(%__MODULE__{} = sidebars) do
    active_id = if sidebars.active_id == "observatory", do: nil, else: sidebars.active_id
    %{sidebars | active_id: active_id, observatory: Observatory.close(sidebars.observatory)}
  end

  @doc "Expires a matching Observatory refresh token."
  @spec expire_observatory(t(), reference()) :: {:collect | :stale, t()}
  def expire_observatory(%__MODULE__{} = sidebars, token) do
    case Observatory.expire(sidebars.observatory, token) do
      {result, observatory} -> {result, %{sidebars | observatory: observatory}}
    end
  end

  @doc "Completes a matching Observatory collection."
  @spec complete_observatory(
          t(),
          reference(),
          MingaEditor.Observatory.Data.t(),
          Observatory.timer()
        ) ::
          {:accepted | :stale, t()}
  def complete_observatory(%__MODULE__{} = sidebars, token, data, next_timer) do
    case Observatory.complete(sidebars.observatory, token, data, next_timer) do
      {result, observatory} -> {result, %{sidebars | observatory: observatory}}
    end
  end

  @doc "Replaces Observatory data without changing refresh correlation."
  @spec replace_observatory_data(t(), MingaEditor.Observatory.Data.t() | nil) :: t()
  def replace_observatory_data(%__MODULE__{} = sidebars, data),
    do: %{sidebars | observatory: Observatory.replace_data(sidebars.observatory, data)}

  @doc "Shows or dismisses Observatory process inspection."
  @spec inspect_observatory(t(), MingaEditor.Observatory.Inspection.t() | nil) :: t()
  def inspect_observatory(%__MODULE__{} = sidebars, inspection),
    do: %{sidebars | observatory: Observatory.inspect(sidebars.observatory, inspection)}
end
