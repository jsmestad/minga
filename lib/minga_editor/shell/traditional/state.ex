defmodule MingaEditor.Shell.Traditional.State do
  @moduledoc """
  Presentation state for the traditional tab-based editor shell.

  These fields are presentation concerns: they control how the editor
  looks and behaves visually, but have no effect on the core editing
  model. Each field was migrated from `MingaEditor.State` as part of
  Phase F of the Core/Shell separation.

  All `set_X`/`get_X` methods that operate on shell fields live here.
  `MingaEditor.State` retains thin wrappers that delegate through
  `update_shell_state/2` for backward compatibility.
  """

  alias MingaEditor.BottomPanel
  alias MingaEditor.HoverPopup
  alias MingaEditor.NavFlash
  alias MingaEditor.Observatory
  alias MingaEditor.YankFlash
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.WhichKey
  alias Minga.Tool.Manager, as: ToolManager
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel

  @typedoc "Git toast shown after a remote operation completes."
  @type git_toast :: ProtocolGUI.git_toast() | nil
  @type git_status_panel :: GitStatusPanel.t()
  @type git_status_tui_state :: struct()

  @git_status_tui_state_module :"Elixir.MingaGitPorcelain.Shell.Traditional.GitStatus.TuiState"

  @type t :: %__MODULE__{
          nav_flash: NavFlash.t() | nil,
          yank_flash: YankFlash.t() | nil,
          hover_popup: HoverPopup.t() | nil,
          status_msg: String.t() | nil,
          whichkey: WhichKey.t(),
          bottom_panel: BottomPanel.t(),
          git_status_panel: git_status_panel() | nil,
          git_status_tui_state: git_status_tui_state() | nil,
          sidebar_active_id: String.t() | nil,
          observatory_visible: boolean(),
          observatory_data: Observatory.Data.t() | nil,
          observatory_timer: {reference(), reference()} | nil,
          observatory_inspection: Observatory.Inspection.t() | nil,
          git_toast: git_toast(),
          tab_bar: TabBar.t() | nil,
          agent: AgentState.t(),
          modal: ModalOverlay.t(),
          inline_asks: InlineAsk.store(),
          inline_edits: InlineEdit.store(),
          modeline_click_regions: [MingaEditor.Shell.Traditional.Modeline.click_region()],
          tab_bar_click_regions: [MingaEditor.Shell.Traditional.TabBarRenderer.click_region()],
          warning_popup_timer: reference() | nil,
          signature_help: MingaEditor.SignatureHelp.t() | nil,
          tool_declined: MapSet.t(),
          tool_prompt_queue: [atom()],
          suppress_tool_prompts: boolean(),
          space_leader_pending: boolean(),
          space_leader_timer: reference() | nil
        }

  defstruct nav_flash: nil,
            yank_flash: nil,
            hover_popup: nil,
            status_msg: nil,
            whichkey: %WhichKey{},
            bottom_panel: %BottomPanel{},
            git_status_panel: nil,
            git_status_tui_state: nil,
            sidebar_active_id: nil,
            observatory_visible: false,
            observatory_data: nil,
            observatory_timer: nil,
            observatory_inspection: nil,
            git_toast: nil,
            tab_bar: nil,
            agent: %AgentState{},
            modal: :none,
            inline_asks: %{},
            inline_edits: %{},
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            warning_popup_timer: nil,
            signature_help: nil,
            tool_declined: MapSet.new(),
            tool_prompt_queue: [],
            suppress_tool_prompts: false,
            space_leader_pending: false,
            space_leader_timer: nil

  # ── Status message ─────────────────────────────────────────────────────────

  @doc "Returns the transient status message, or nil."
  @spec status_msg(t()) :: String.t() | nil
  def status_msg(%{status_msg: msg}), do: msg

  @doc "Sets the transient status message shown in the modeline."
  @spec set_status(t(), String.t()) :: t()
  def set_status(%{} = ss, msg) when is_binary(msg) do
    Map.put(ss, :status_msg, msg)
  end

  @doc "Clears the transient status message."
  @spec clear_status(t()) :: t()
  def clear_status(%{status_msg: nil} = ss), do: ss

  def clear_status(%{} = ss) do
    Map.put(ss, :status_msg, nil)
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

  # ── Yank flash ────────────────────────────────────────────────────────────

  @doc "Returns the yank flash state, or nil when inactive."
  @spec yank_flash(t()) :: YankFlash.t() | nil
  def yank_flash(%{yank_flash: flash}), do: flash

  @doc "Sets the yank flash state."
  @spec set_yank_flash(t(), YankFlash.t()) :: t()
  def set_yank_flash(%{} = ss, %YankFlash{} = flash) do
    %{ss | yank_flash: flash}
  end

  @doc "Cancels the yank flash animation."
  @spec cancel_yank_flash(t()) :: t()
  def cancel_yank_flash(%{} = ss) do
    %{ss | yank_flash: nil}
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
  @spec git_status_panel(t()) :: git_status_panel() | nil
  def git_status_panel(%{git_status_panel: data}), do: data

  @doc "Sets the git status panel data."
  @spec set_git_status_panel(t(), git_status_panel() | nil) :: t()
  def set_git_status_panel(%{} = ss, nil), do: %{ss | git_status_panel: nil}

  def set_git_status_panel(%{} = ss, data) do
    %{ss | git_status_panel: GitStatusPanel.new(data)}
  end

  @doc "Returns the TUI-only git status view state, or nil."
  @spec git_status_tui_state(t()) :: git_status_tui_state() | nil
  def git_status_tui_state(%{git_status_tui_state: tui}), do: tui

  @doc "Sets the TUI-only git status view state."
  @spec set_git_status_tui_state(t(), git_status_tui_state() | nil) :: t()
  def set_git_status_tui_state(%{} = ss, nil), do: %{ss | git_status_tui_state: nil}

  def set_git_status_tui_state(%{} = ss, tui) do
    if git_status_tui_state?(tui), do: %{ss | git_status_tui_state: tui}, else: ss
  end

  @doc "Refreshes existing TUI-only git status view state after shared entries change."
  @spec refresh_git_status_tui_state(t(), [Minga.Git.StatusEntry.t()]) :: t()
  def refresh_git_status_tui_state(%{git_status_tui_state: nil} = ss, _entries), do: ss

  def refresh_git_status_tui_state(%{git_status_tui_state: tui} = ss, entries) do
    module = :"Elixir.MingaGitPorcelain.Shell.Traditional.GitStatus.TuiState"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :refresh, 2) do
      refreshed = :erlang.apply(module, :refresh, [tui, entries])

      if git_status_tui_state?(refreshed), do: %{ss | git_status_tui_state: refreshed}, else: ss
    else
      ss
    end
  end

  @spec git_status_tui_state?(term()) :: boolean()
  defp git_status_tui_state?(value) do
    Code.ensure_loaded?(@git_status_tui_state_module) and
      is_struct(value, @git_status_tui_state_module)
  end

  @spec git_porcelain_running?() :: boolean()
  defp git_porcelain_running? do
    case Process.whereis(Minga.Extension.Registry) do
      nil -> false
      _pid -> git_porcelain_running_in_registry?()
    end
  catch
    :exit, _reason -> false
  end

  @spec git_porcelain_running_in_registry?() :: boolean()
  defp git_porcelain_running_in_registry? do
    case Minga.Extension.Registry.get(:minga_git_porcelain) do
      {:ok, %{status: :running}} -> true
      _ -> false
    end
  end

  @doc "Clears the git status panel."
  @spec close_git_status_panel(t()) :: t()
  def close_git_status_panel(%{} = ss) do
    %{ss | git_status_panel: nil, git_status_tui_state: nil}
  end

  @doc "Returns the active native sidebar id, or nil when the renderer should derive one."
  @spec sidebar_active_id(t()) :: String.t() | nil
  def sidebar_active_id(%{sidebar_active_id: id}), do: id

  @doc "Sets the active native sidebar id."
  @spec set_sidebar_active_id(t(), String.t() | nil) :: t()
  def set_sidebar_active_id(%{} = ss, id) when is_binary(id) or is_nil(id) do
    %{ss | sidebar_active_id: id}
  end

  # ── BEAM Observatory ──────────────────────────────────────────────────────

  @doc "Returns true when the BEAM Observatory sidebar is visible."
  @spec observatory_visible?(t()) :: boolean()
  def observatory_visible?(%{observatory_visible: visible}), do: visible

  @doc "Opens the BEAM Observatory sidebar."
  @spec open_observatory(t(), {reference(), reference()} | nil) :: t()
  def open_observatory(%{} = ss, timer) do
    %{ss | observatory_visible: true, observatory_timer: timer, observatory_inspection: nil}
  end

  @doc "Closes the BEAM Observatory sidebar."
  @spec close_observatory(t()) :: t()
  def close_observatory(%{} = ss) do
    %{
      ss
      | observatory_visible: false,
        observatory_data: nil,
        observatory_timer: nil,
        observatory_inspection: nil
    }
  end

  @doc "Stores the latest BEAM Observatory tree data."
  @spec set_observatory_data(t(), Observatory.Data.t() | nil) :: t()
  def set_observatory_data(%{} = ss, data) do
    %{ss | observatory_data: data}
  end

  @doc "Stores the timer reference for the next BEAM Observatory refresh."
  @spec set_observatory_timer(t(), {reference(), reference()} | nil) :: t()
  def set_observatory_timer(%{} = ss, timer) do
    %{ss | observatory_timer: timer}
  end

  @doc "Stores process inspection data for the native float popup."
  @spec set_observatory_inspection(t(), Observatory.Inspection.t() | nil) :: t()
  def set_observatory_inspection(%{} = ss, inspection) do
    %{ss | observatory_inspection: inspection}
  end

  # ── Git toast ─────────────────────────────────────────────────────────────

  @doc "Returns the git toast, or nil."
  @spec git_toast(t()) :: git_toast()
  def git_toast(%{git_toast: toast}), do: toast

  @doc "Sets the git toast shown after a remote operation."
  @spec set_git_toast(t(), git_toast()) :: t()
  def set_git_toast(%{} = ss, toast), do: %{ss | git_toast: toast}

  @doc "Clears the git toast."
  @spec clear_git_toast(t()) :: t()
  def clear_git_toast(%{} = ss), do: %{ss | git_toast: nil}

  @doc "Clears the git toast only when its dismissal reference matches."
  @spec clear_git_toast(t(), reference()) :: t()
  def clear_git_toast(%{git_toast: %{dismiss_ref: dismiss_ref}} = ss, dismiss_ref),
    do: %{ss | git_toast: nil}

  def clear_git_toast(%{} = ss, _dismiss_ref), do: ss

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

  # ── Modal overlay ──────────────────────────────────────────────────────────

  @doc "Returns the active modal overlay value (`:none` when no modal is open)."
  @spec modal(t()) :: ModalOverlay.t()
  def modal(%{modal: m}), do: m

  @doc """
  Replaces the modal overlay value.

  This is a low-level setter for `MingaEditor.State.ModalOverlay`. Normal
  callers should use `ModalOverlay.open/3`, `transition/3`, `close/1`, or
  `dismiss/1` rather than calling this directly.
  """
  @spec set_modal(t(), ModalOverlay.t()) :: t()
  def set_modal(%{} = ss, modal) do
    %{ss | modal: modal}
  end

  # ── Inline ask ─────────────────────────────────────────────────────────────

  @doc "Returns the inline ask store."
  @spec inline_asks(t() | map()) :: InlineAsk.store()
  def inline_asks(%{inline_asks: asks}), do: asks
  def inline_asks(_ss), do: %{}

  @doc "Replaces the inline ask store."
  @spec set_inline_asks(t() | map(), InlineAsk.store()) :: t() | map()
  def set_inline_asks(%{inline_asks: _} = ss, asks) when is_map(asks) do
    %{ss | inline_asks: asks}
  end

  def set_inline_asks(ss, _asks), do: ss

  @doc "Returns the inline edit store."
  @spec inline_edits(t() | map()) :: InlineEdit.store()
  def inline_edits(%{inline_edits: edits}), do: edits
  def inline_edits(_ss), do: %{}

  @doc "Replaces the inline edit store."
  @spec set_inline_edits(t() | map(), InlineEdit.store()) :: t() | map()
  def set_inline_edits(%{inline_edits: _} = ss, edits) when is_map(edits) do
    %{ss | inline_edits: edits}
  end

  def set_inline_edits(ss, _edits), do: ss

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

  @doc "Sets whether a CUA space leader sequence is pending."
  @spec set_space_leader_pending(t(), boolean()) :: t()
  def set_space_leader_pending(%{} = ss, value) when is_boolean(value) do
    %{ss | space_leader_pending: value}
  end

  @doc "Sets the CUA space leader timer reference."
  @spec set_space_leader_timer(t(), reference() | nil) :: t()
  def set_space_leader_timer(%{} = ss, timer) do
    %{ss | space_leader_timer: timer}
  end
end
