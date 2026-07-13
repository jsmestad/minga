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
  alias MingaEditor.Observatory
  alias MingaEditor.Shell.Traditional.Flashes
  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.WhichKey
  alias Minga.Tool.Manager, as: ToolManager
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel

  @type git_status_panel :: GitStatusPanel.t()
  @type git_status_tui_state :: struct()
  @type tab_bar_command ::
          atom() | {:workspace_goto, non_neg_integer()} | {:tab_goto_id, pos_integer()}
  @type tab_bar_click_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(),
           command :: tab_bar_command()}
          | {row :: non_neg_integer(), col_start :: non_neg_integer(),
             col_end :: non_neg_integer(), command :: tab_bar_command()}

  @git_status_tui_state_module :"Elixir.MingaGitPorcelain.Shell.Traditional.GitStatus.TuiState"

  @type t :: %__MODULE__{
          flashes: Flashes.t(),
          hover_popup: HoverPopup.t() | nil,
          notice: Notice.t(),
          whichkey: WhichKey.t(),
          bottom_panel: BottomPanel.t(),
          git_status_panel: git_status_panel() | nil,
          git_status_tui_state: git_status_tui_state() | nil,
          sidebar_active_id: String.t() | nil,
          observatory_visible: boolean(),
          observatory_data: Observatory.Data.t() | nil,
          observatory_timer: {reference(), reference()} | nil,
          observatory_inspection: Observatory.Inspection.t() | nil,
          git_toast: GitToast.t(),
          tab_bar: TabBar.t() | nil,
          agent: AgentState.t(),
          modal: ModalOverlay.t(),
          inline_asks: InlineAsk.store(),
          inline_edits: InlineEdit.store(),
          modeline_click_regions: [MingaEditor.Shell.Traditional.Modeline.click_region()],
          tab_bar_click_regions: [tab_bar_click_region()],
          signature_help: MingaEditor.SignatureHelp.t() | nil,
          tool_declined: MapSet.t(),
          tool_prompt_queue: [atom()],
          suppress_tool_prompts: boolean(),
          space_leader_pending: boolean(),
          space_leader_timer: reference() | nil
        }

  defstruct flashes: %Flashes{},
            hover_popup: nil,
            notice: %Notice{},
            whichkey: %WhichKey{},
            bottom_panel: %BottomPanel{},
            git_status_panel: nil,
            git_status_tui_state: nil,
            sidebar_active_id: nil,
            observatory_visible: false,
            observatory_data: nil,
            observatory_timer: nil,
            observatory_inspection: nil,
            git_toast: %GitToast{},
            tab_bar: nil,
            agent: %AgentState{},
            modal: :none,
            inline_asks: %{},
            inline_edits: %{},
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            signature_help: nil,
            tool_declined: MapSet.new(),
            tool_prompt_queue: [],
            suppress_tool_prompts: false,
            space_leader_pending: false,
            space_leader_timer: nil

  @doc "Controls whether missing-tool prompts are suppressed."
  @spec set_suppress_tool_prompts(t(), boolean()) :: t()
  def set_suppress_tool_prompts(%__MODULE__{} = state, suppress?) when is_boolean(suppress?) do
    %{state | suppress_tool_prompts: suppress?}
  end

  # ── Focused transient owners ──────────────────────────────────────────────

  @doc "Applies the notice publish transition."
  @spec publish_notice(t(), String.t()) :: t()
  def publish_notice(%__MODULE__{} = state, message),
    do: %{state | notice: Notice.publish(state.notice, message)}

  @doc "Records a notice timer for the matching notice identity."
  @spec record_notice_timer(t(), Notice.id(), reference()) :: t()
  def record_notice_timer(%__MODULE__{} = state, id, timer),
    do: %{state | notice: Notice.record_timer(state.notice, id, timer)}

  @doc "Acknowledges the current notice."
  @spec acknowledge_notice(t()) :: t()
  def acknowledge_notice(%__MODULE__{} = state),
    do: %{state | notice: Notice.acknowledge(state.notice)}

  @doc "Dismisses the current notice."
  @spec dismiss_notice(t()) :: t()
  def dismiss_notice(%__MODULE__{} = state), do: %{state | notice: Notice.dismiss(state.notice)}

  @doc "Applies a matching notice timeout."
  @spec timeout_notice(t(), Notice.id()) :: t()
  def timeout_notice(%__MODULE__{} = state, id),
    do: %{state | notice: Notice.timeout(state.notice, id)}

  @doc "Replaces only the navigation flash."
  @spec replace_nav_flash(t(), non_neg_integer()) :: t()
  def replace_nav_flash(%__MODULE__{} = state, line),
    do: %{state | flashes: Flashes.replace_nav(state.flashes, line)}

  @doc "Records only the matching navigation flash timer."
  @spec record_nav_flash_timer(t(), non_neg_integer(), reference()) :: t()
  def record_nav_flash_timer(%__MODULE__{} = state, generation, timer),
    do: %{state | flashes: Flashes.record_nav_timer(state.flashes, generation, timer)}

  @doc "Advances only the matching navigation flash generation."
  @spec advance_nav_flash(t(), non_neg_integer()) :: {:continue | :done | :stale, t()}
  def advance_nav_flash(%__MODULE__{} = state, generation) do
    case Flashes.advance_nav(state.flashes, generation) do
      {result, flashes} -> {result, %{state | flashes: flashes}}
    end
  end

  @doc "Cancels only the navigation flash."
  @spec cancel_nav_flash(t()) :: t()
  def cancel_nav_flash(%__MODULE__{} = state),
    do: %{state | flashes: Flashes.cancel_nav(state.flashes)}

  @doc "Replaces only the yank flash."
  @spec replace_yank_flash(t(), pid(), tuple(), tuple(), atom()) :: t()
  def replace_yank_flash(%__MODULE__{} = state, buf, start_pos, end_pos, range_type),
    do: %{
      state
      | flashes: Flashes.replace_yank(state.flashes, buf, start_pos, end_pos, range_type)
    }

  @doc "Records only the matching yank flash timer."
  @spec record_yank_flash_timer(t(), non_neg_integer(), reference()) :: t()
  def record_yank_flash_timer(%__MODULE__{} = state, generation, timer),
    do: %{state | flashes: Flashes.record_yank_timer(state.flashes, generation, timer)}

  @doc "Advances only the matching yank flash generation."
  @spec advance_yank_flash(t(), non_neg_integer()) :: {:continue | :done | :stale, t()}
  def advance_yank_flash(%__MODULE__{} = state, generation) do
    case Flashes.advance_yank(state.flashes, generation) do
      {result, flashes} -> {result, %{state | flashes: flashes}}
    end
  end

  @doc "Cancels only the yank flash."
  @spec cancel_yank_flash(t()) :: t()
  def cancel_yank_flash(%__MODULE__{} = state),
    do: %{state | flashes: Flashes.cancel_yank(state.flashes)}

  @doc "Publishes a protocol-independent Git toast."
  @spec publish_git_toast(t(), String.t(), GitToast.level(), GitToast.action()) :: t()
  def publish_git_toast(%__MODULE__{} = state, message, level, action),
    do: %{state | git_toast: GitToast.publish(state.git_toast, message, level, action)}

  @doc "Records a Git-toast timer for the matching identity."
  @spec record_git_toast_timer(t(), GitToast.id(), reference()) :: t()
  def record_git_toast_timer(%__MODULE__{} = state, id, timer),
    do: %{state | git_toast: GitToast.record_timer(state.git_toast, id, timer)}

  @doc "Dismisses the current Git toast."
  @spec dismiss_git_toast(t()) :: t()
  def dismiss_git_toast(%__MODULE__{} = state),
    do: %{state | git_toast: GitToast.dismiss(state.git_toast)}

  @doc "Dismisses a Git toast only when its identity still matches."
  @spec dismiss_git_toast(t(), GitToast.id()) :: t()
  def dismiss_git_toast(%__MODULE__{} = state, id),
    do: %{state | git_toast: GitToast.dismiss(state.git_toast, id)}

  @doc "Times out a matching auto-dismiss Git toast."
  @spec timeout_git_toast(t(), GitToast.id()) :: t()
  def timeout_git_toast(%__MODULE__{} = state, id),
    do: %{state | git_toast: GitToast.timeout(state.git_toast, id)}

  # ── Hover popup ────────────────────────────────────────────────────────────

  @doc "Returns the hover popup state, or nil when not showing."
  @spec hover_popup(t()) :: HoverPopup.t() | nil
  def hover_popup(%{hover_popup: popup}), do: popup

  @doc "Shows newly produced hover content, replacing prior content."
  @spec show_hover_popup(t(), HoverPopup.t()) :: t()
  def show_hover_popup(%__MODULE__{} = state, %HoverPopup{} = popup),
    do: %{state | hover_popup: HoverPopup.replace(state.hover_popup, popup)}

  @doc "Dismisses the hover popup."
  @spec dismiss_hover_popup(t()) :: t()
  def dismiss_hover_popup(%__MODULE__{} = state),
    do: %{state | hover_popup: HoverPopup.dismiss(state.hover_popup)}

  @doc "Shows newly produced signature-help content."
  @spec show_signature_help(t(), MingaEditor.SignatureHelp.t()) :: t()
  def show_signature_help(%__MODULE__{} = state, signature_help),
    do: %{
      state
      | signature_help: MingaEditor.SignatureHelp.replace(state.signature_help, signature_help)
    }

  @doc "Cycles to the next signature through its value owner."
  @spec next_signature_help(t()) :: t()
  def next_signature_help(
        %__MODULE__{signature_help: %MingaEditor.SignatureHelp{} = signature_help} = state
      ),
      do: %{
        state
        | signature_help: MingaEditor.SignatureHelp.next_signature(signature_help)
      }

  def next_signature_help(%__MODULE__{} = state), do: state

  @doc "Cycles to the previous signature through its value owner."
  @spec previous_signature_help(t()) :: t()
  def previous_signature_help(
        %__MODULE__{signature_help: %MingaEditor.SignatureHelp{} = signature_help} = state
      ),
      do: %{
        state
        | signature_help: MingaEditor.SignatureHelp.prev_signature(signature_help)
      }

  def previous_signature_help(%__MODULE__{} = state), do: state

  @doc "Dismisses signature help through its value owner."
  @spec dismiss_signature_help(t()) :: t()
  def dismiss_signature_help(%__MODULE__{} = state),
    do: %{
      state
      | signature_help: MingaEditor.SignatureHelp.dismiss(state.signature_help)
    }

  @doc "Suppresses hover and signature help below a higher interactive surface."
  @spec suppress_lower_transients(t()) :: t()
  def suppress_lower_transients(%__MODULE__{} = state) do
    state
    |> dismiss_hover_popup()
    |> dismiss_signature_help()
  end

  # ── Which-key ──────────────────────────────────────────────────────────────

  @doc "Returns the which-key popup state."
  @spec whichkey(t()) :: WhichKey.t()
  def whichkey(%{whichkey: wk}), do: wk

  @doc "Begins a hidden which-key lifecycle generation."
  @spec begin_whichkey(t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: t()
  def begin_whichkey(%__MODULE__{} = state, node, prefix_keys),
    do: %{state | whichkey: WhichKey.begin(state.whichkey, node, prefix_keys)}

  @doc "Advances the which-key leader prefix."
  @spec progress_whichkey(t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: t()
  def progress_whichkey(%__MODULE__{} = state, node, prefix_keys),
    do: %{state | whichkey: WhichKey.progress(state.whichkey, node, prefix_keys)}

  @doc "Records a which-key timer for the matching generation."
  @spec record_whichkey_timer(t(), WhichKey.generation(), reference()) :: t()
  def record_whichkey_timer(%__MODULE__{} = state, generation, timer),
    do: %{state | whichkey: WhichKey.record_timer(state.whichkey, generation, timer)}

  @doc "Reveals only the matching which-key generation."
  @spec reveal_whichkey(t(), WhichKey.generation()) :: t()
  def reveal_whichkey(%__MODULE__{} = state, generation),
    do: %{state | whichkey: WhichKey.reveal(state.whichkey, generation)}

  @doc "Dismisses which-key through its value owner."
  @spec dismiss_whichkey(t()) :: t()
  def dismiss_whichkey(%__MODULE__{} = state),
    do: %{state | whichkey: WhichKey.dismiss(state.whichkey)}

  @doc "Moves which-key to the next page."
  @spec next_whichkey_page(t()) :: t()
  def next_whichkey_page(%__MODULE__{} = state),
    do: %{state | whichkey: WhichKey.next_page(state.whichkey)}

  @doc "Moves which-key to the previous page."
  @spec previous_whichkey_page(t()) :: t()
  def previous_whichkey_page(%__MODULE__{} = state),
    do: %{state | whichkey: WhichKey.previous_page(state.whichkey)}

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

  @doc "Opens a modal through the conflict-sticky value transition."
  @spec open_modal(t(), ModalOverlay.variant(), ModalOverlay.payload()) :: t()
  def open_modal(%__MODULE__{} = state, variant, payload),
    do: %{state | modal: ModalOverlay.open(state.modal, variant, payload)}

  @doc "Transitions the modal value unconditionally."
  @spec transition_modal(t(), ModalOverlay.variant(), ModalOverlay.payload()) :: t()
  def transition_modal(%__MODULE__{} = state, variant, payload),
    do: %{state | modal: ModalOverlay.transition(state.modal, variant, payload)}

  @doc "Closes a completed modal."
  @spec close_modal(t()) :: t()
  def close_modal(%__MODULE__{} = state), do: %{state | modal: ModalOverlay.close(state.modal)}

  @doc "Dismisses a canceled modal."
  @spec dismiss_modal(t()) :: t()
  def dismiss_modal(%__MODULE__{} = state),
    do: %{state | modal: ModalOverlay.dismiss(state.modal)}

  @doc "Updates the active completion value."
  @spec update_modal_completion(t(), (Minga.Editing.Completion.t() ->
                                        Minga.Editing.Completion.t())) ::
          t()
  def update_modal_completion(%__MODULE__{} = state, update),
    do: %{state | modal: ModalOverlay.update_completion(state.modal, update)}

  @doc "Records completion trigger lifecycle with explicit active-tab context."
  @spec put_modal_completion_trigger(t(), MingaEditor.CompletionTrigger.t(), term() | nil) :: t()
  def put_modal_completion_trigger(%__MODULE__{} = state, trigger, active_tab_id),
    do: %{
      state
      | modal: ModalOverlay.put_completion_trigger(state.modal, trigger, active_tab_id)
    }

  @doc "Dismisses stale completion using the now-active tab id."
  @spec dismiss_stale_modal_completion(t(), term() | nil) :: t()
  def dismiss_stale_modal_completion(%__MODULE__{} = state, active_tab_id),
    do: %{state | modal: ModalOverlay.dismiss_if_stale(state.modal, active_tab_id)}

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

  @doc "Replaces the pending tool-install prompt queue."
  @spec set_tool_prompt_queue(t(), [atom()]) :: t()
  def set_tool_prompt_queue(%__MODULE__{} = state, queue) when is_list(queue) do
    %{state | tool_prompt_queue: queue}
  end

  @doc "Replaces tool-prompt decisions and the pending queue atomically."
  @spec set_tool_prompt_state(t(), [atom()], MapSet.t(atom())) :: t()
  def set_tool_prompt_state(%__MODULE__{} = state, queue, declined)
      when is_list(queue) do
    %{state | tool_prompt_queue: queue, tool_declined: declined}
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
