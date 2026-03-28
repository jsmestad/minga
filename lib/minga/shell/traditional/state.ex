defmodule Minga.Shell.Traditional.State do
  @moduledoc """
  Presentation state for the traditional tab-based editor shell.

  These fields are presentation concerns: they control how the editor
  looks and behaves visually, but have no effect on the core editing
  model. Each field was migrated from `Minga.Editor.State` as part of
  Phase F of the Core/Shell separation.

  All `set_X`/`get_X` methods that operate on shell fields live here.
  `Minga.Editor.State` retains thin wrappers that delegate through
  `update_shell_state/2` for backward compatibility.
  """

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.Dashboard
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.NavFlash
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.Prompt
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.WhichKey
  alias Minga.Tool.Manager, as: ToolManager

  @type t :: %__MODULE__{
          nav_flash: NavFlash.t() | nil,
          hover_popup: HoverPopup.t() | nil,
          dashboard: Dashboard.state() | nil,
          status_msg: String.t() | nil,
          picker_ui: Picker.t(),
          prompt_ui: Prompt.t(),
          whichkey: WhichKey.t(),
          bottom_panel: BottomPanel.t(),
          git_status_panel: Minga.Frontend.Protocol.GUI.git_status_data() | nil,
          tab_bar: TabBar.t() | nil,
          agent: AgentState.t(),
          modeline_click_regions: [Minga.Shell.Traditional.Modeline.click_region()],
          tab_bar_click_regions: [Minga.Shell.Traditional.TabBarRenderer.click_region()],
          warning_popup_timer: reference() | nil,
          signature_help: Minga.Editor.SignatureHelp.t() | nil,
          tool_declined: MapSet.t(),
          tool_prompt_queue: [atom()],
          suppress_tool_prompts: boolean()
        }

  defstruct nav_flash: nil,
            hover_popup: nil,
            dashboard: nil,
            status_msg: nil,
            picker_ui: %Picker{},
            prompt_ui: %Prompt{},
            whichkey: %WhichKey{},
            bottom_panel: %BottomPanel{},
            git_status_panel: nil,
            tab_bar: nil,
            agent: %AgentState{},
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            warning_popup_timer: nil,
            signature_help: nil,
            tool_declined: MapSet.new(),
            tool_prompt_queue: [],
            suppress_tool_prompts: false

  # ── Status message ─────────────────────────────────────────────────────────

  @doc "Returns the transient status message, or nil."
  @spec status_msg(t()) :: String.t() | nil
  def status_msg(%{status_msg: msg}), do: msg

  @doc "Sets the transient status message shown in the modeline."
  @spec set_status(t(), String.t()) :: t()
  def set_status(%{} = ss, msg) when is_binary(msg) do
    %{ss | status_msg: msg}
  end

  @doc "Clears the transient status message."
  @spec clear_status(t()) :: t()
  def clear_status(%{} = ss) do
    %{ss | status_msg: nil}
  end

  # ── Nav flash ──────────────────────────────────────────────────────────────

  @doc "Returns the nav flash state, or nil when inactive."
  @spec nav_flash(t()) :: NavFlash.t() | nil
  def nav_flash(%{nav_flash: flash}), do: flash

  @doc "Sets the nav flash state."
  @spec set_nav_flash(t(), NavFlash.t()) :: t()
  def set_nav_flash(%{} = ss, %NavFlash{} = flash) do
    %{ss | nav_flash: flash}
  end

  @doc "Cancels the nav flash animation."
  @spec cancel_nav_flash(t()) :: t()
  def cancel_nav_flash(%{} = ss) do
    %{ss | nav_flash: nil}
  end

  # ── Hover popup ────────────────────────────────────────────────────────────

  @doc "Returns the hover popup state, or nil when not showing."
  @spec hover_popup(t()) :: HoverPopup.t() | nil
  def hover_popup(%{hover_popup: popup}), do: popup

  @doc "Sets the hover popup state."
  @spec set_hover_popup(t(), HoverPopup.t()) :: t()
  def set_hover_popup(%{} = ss, %HoverPopup{} = popup) do
    %{ss | hover_popup: popup}
  end

  @doc "Dismisses the hover popup."
  @spec dismiss_hover_popup(t()) :: t()
  def dismiss_hover_popup(%{} = ss) do
    %{ss | hover_popup: nil}
  end

  # ── Dashboard ──────────────────────────────────────────────────────────────

  @doc "Returns the dashboard home screen state, or nil."
  @spec dashboard(t()) :: Dashboard.state() | nil
  def dashboard(%{dashboard: dash}), do: dash

  @doc "Sets the dashboard home screen state."
  @spec set_dashboard(t(), Dashboard.state()) :: t()
  def set_dashboard(%{} = ss, dash) when is_map(dash) do
    %{ss | dashboard: dash}
  end

  @doc "Closes the dashboard home screen."
  @spec close_dashboard(t()) :: t()
  def close_dashboard(%{} = ss) do
    %{ss | dashboard: nil}
  end

  # ── Picker UI ──────────────────────────────────────────────────────────────

  @doc "Returns the picker UI state."
  @spec picker_ui(t()) :: Picker.t()
  def picker_ui(%{picker_ui: pui}), do: pui

  @doc "Replaces the picker UI state."
  @spec set_picker_ui(t(), Picker.t()) :: t()
  def set_picker_ui(%{} = ss, pui) do
    %{ss | picker_ui: pui}
  end

  @doc "Applies a function to the picker UI state."
  @spec update_picker_ui(t(), (Picker.t() -> Picker.t())) :: t()
  def update_picker_ui(%{picker_ui: pui} = ss, fun) when is_function(fun, 1) do
    %{ss | picker_ui: fun.(pui)}
  end

  # ── Prompt UI ──────────────────────────────────────────────────────────────

  @doc "Returns the prompt UI state."
  @spec prompt_ui(t()) :: Prompt.t()
  def prompt_ui(%{prompt_ui: p}), do: p

  @doc "Replaces the prompt UI state."
  @spec set_prompt_ui(t(), Prompt.t()) :: t()
  def set_prompt_ui(%{} = ss, prompt) do
    %{ss | prompt_ui: prompt}
  end

  # ── Which-key ──────────────────────────────────────────────────────────────

  @doc "Returns the which-key popup state."
  @spec whichkey(t()) :: WhichKey.t()
  def whichkey(%{whichkey: wk}), do: wk

  @doc "Replaces the which-key popup state."
  @spec set_whichkey(t(), WhichKey.t()) :: t()
  def set_whichkey(%{} = ss, wk) do
    %{ss | whichkey: wk}
  end

  # ── Bottom panel ───────────────────────────────────────────────────────────

  @doc "Returns the bottom panel state."
  @spec bottom_panel(t()) :: BottomPanel.t()
  def bottom_panel(%{bottom_panel: panel}), do: panel

  @doc "Replaces the bottom panel state."
  @spec set_bottom_panel(t(), BottomPanel.t()) :: t()
  def set_bottom_panel(%{} = ss, panel) do
    %{ss | bottom_panel: panel}
  end

  # ── Git status panel ───────────────────────────────────────────────────────

  @doc "Returns the git status panel data, or nil."
  @spec git_status_panel(t()) :: Minga.Frontend.Protocol.GUI.git_status_data() | nil
  def git_status_panel(%{git_status_panel: data}), do: data

  @doc "Sets the git status panel data."
  @spec set_git_status_panel(t(), map() | nil) :: t()
  def set_git_status_panel(%{} = ss, data) do
    %{ss | git_status_panel: data}
  end

  @doc "Clears the git status panel."
  @spec close_git_status_panel(t()) :: t()
  def close_git_status_panel(%{} = ss) do
    %{ss | git_status_panel: nil}
  end

  # ── Tab bar ────────────────────────────────────────────────────────────────

  @doc "Returns the tab bar state, or nil."
  @spec tab_bar(t()) :: TabBar.t() | nil
  def tab_bar(%{tab_bar: tb}), do: tb

  @doc "Replaces the tab bar state."
  @spec set_tab_bar(t(), TabBar.t() | nil) :: t()
  def set_tab_bar(%{} = ss, tb) do
    %{ss | tab_bar: tb}
  end

  # ── Agent lifecycle ────────────────────────────────────────────────────────

  @doc "Returns the agent session lifecycle state."
  @spec agent(t()) :: AgentState.t()
  def agent(%{agent: a}), do: a

  @doc "Replaces the agent session lifecycle state."
  @spec set_agent(t(), AgentState.t()) :: t()
  def set_agent(%{} = ss, agent) do
    %{ss | agent: agent}
  end

  # ── Tool prompt helpers ────────────────────────────────────────────────────

  @doc """
  Returns true if the given tool should NOT be prompted for installation.

  A tool is skipped when it's already declined this session, already
  installed, currently being installed, or already in the prompt queue.
  """
  @spec skip_tool_prompt?(t(), atom()) :: boolean()
  def skip_tool_prompt?(%{} = ss, tool_name) do
    MapSet.member?(ss.tool_declined, tool_name) or
      ToolManager.installed?(tool_name) or
      MapSet.member?(ToolManager.installing(), tool_name) or
      tool_name in ss.tool_prompt_queue
  end
end
