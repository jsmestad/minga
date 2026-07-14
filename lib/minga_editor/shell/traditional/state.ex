defmodule MingaEditor.Shell.Traditional.State do
  @moduledoc """
  Presentation state for the traditional tab-based editor shell.

  This value coordinates focused owners for sidebar, agent-surface, input,
  and existing independent transient lifecycles. Effects and Editor-root
  transitions remain in their focused workflows and handlers.
  """

  alias MingaEditor.BottomPanel
  alias MingaEditor.HoverPopup
  alias MingaEditor.SignatureHelp
  alias MingaEditor.Shell.Traditional.AgentSurfaces
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.Flashes
  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.Shell.Traditional.InputState
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.Sidebars
  alias MingaEditor.Shell.Traditional.SpaceLeader
  alias MingaEditor.Shell.Traditional.ToolPrompts
  alias MingaEditor.Shell.Traditional.YankFlash
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.WhichKey
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.GitStatus.TUIState

  @type git_status_panel :: GitStatusPanel.t()
  @type git_status_tui_state :: Sidebars.git_status_tui_state()
  @type tab_bar_command :: ClickRegions.tab_bar_command()
  @type tab_bar_click_region :: ClickRegions.tab_bar_region()

  @type t :: %__MODULE__{
          flashes: Flashes.t(),
          hover_popup: HoverPopup.t() | nil,
          notice: Notice.t(),
          whichkey: WhichKey.t(),
          bottom_panel: BottomPanel.t(),
          sidebars: Sidebars.t(),
          git_toast: GitToast.t(),
          tab_bar: TabBar.t() | nil,
          agent_surfaces: AgentSurfaces.t(),
          modal: ModalOverlay.t(),
          input: InputState.t(),
          signature_help: SignatureHelp.t() | nil,
          tool_prompts: ToolPrompts.t()
        }

  defstruct flashes: %Flashes{},
            hover_popup: nil,
            notice: %Notice{},
            whichkey: %WhichKey{},
            bottom_panel: %BottomPanel{},
            sidebars: %Sidebars{},
            git_toast: %GitToast{},
            tab_bar: nil,
            agent_surfaces: %AgentSurfaces{},
            modal: :none,
            input: %InputState{},
            signature_help: nil,
            tool_prompts: %ToolPrompts{}

  @doc "Installs the configured missing-tool prompt suppression policy."
  @spec install_tool_prompt_suppression(t(), boolean()) :: t()
  def install_tool_prompt_suppression(%__MODULE__{} = state, suppress?)
      when is_boolean(suppress?) do
    %{state | tool_prompts: ToolPrompts.suppress(state.tool_prompts, suppress?)}
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
  @spec replace_yank_flash(
          t(),
          pid(),
          YankFlash.position(),
          YankFlash.position(),
          YankFlash.range_type()
        ) :: t()
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
  def hover_popup(%__MODULE__{hover_popup: popup}), do: popup

  @doc "Shows newly produced hover content, replacing prior content."
  @spec show_hover_popup(t(), HoverPopup.t()) :: t()
  def show_hover_popup(%__MODULE__{} = state, %HoverPopup{} = popup),
    do: %{state | hover_popup: HoverPopup.replace(state.hover_popup, popup)}

  @doc "Dismisses the hover popup."
  @spec dismiss_hover_popup(t()) :: t()
  def dismiss_hover_popup(%__MODULE__{} = state),
    do: %{state | hover_popup: HoverPopup.dismiss(state.hover_popup)}

  @doc "Shows newly produced signature-help content."
  @spec show_signature_help(t(), SignatureHelp.t()) :: t()
  def show_signature_help(%__MODULE__{} = state, %SignatureHelp{} = signature_help),
    do: %{state | signature_help: SignatureHelp.replace(state.signature_help, signature_help)}

  @doc "Cycles to the next signature through its value owner."
  @spec next_signature_help(t()) :: t()
  def next_signature_help(%__MODULE__{signature_help: %SignatureHelp{} = signature_help} = state),
    do: %{state | signature_help: SignatureHelp.next_signature(signature_help)}

  def next_signature_help(%__MODULE__{} = state), do: state

  @doc "Cycles to the previous signature through its value owner."
  @spec previous_signature_help(t()) :: t()
  def previous_signature_help(
        %__MODULE__{signature_help: %SignatureHelp{} = signature_help} = state
      ),
      do: %{state | signature_help: SignatureHelp.prev_signature(signature_help)}

  def previous_signature_help(%__MODULE__{} = state), do: state

  @doc "Dismisses signature help through its value owner."
  @spec dismiss_signature_help(t()) :: t()
  def dismiss_signature_help(%__MODULE__{} = state),
    do: %{state | signature_help: SignatureHelp.dismiss(state.signature_help)}

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
  def whichkey(%__MODULE__{whichkey: whichkey}), do: whichkey

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
  def bottom_panel(%__MODULE__{bottom_panel: panel}), do: panel

  @doc "Blurs the shell-owned bottom panel."
  @spec blur_bottom_panel(t()) :: t()
  def blur_bottom_panel(%__MODULE__{} = state),
    do: %{state | bottom_panel: BottomPanel.blur(state.bottom_panel)}

  @doc "Installs an exact bottom-panel value."
  @spec install_bottom_panel(t(), BottomPanel.t()) :: t()
  def install_bottom_panel(%__MODULE__{} = state, %BottomPanel{} = panel),
    do: %{state | bottom_panel: panel}

  # ── Sidebar and Observatory lifecycle ─────────────────────────────────────

  @doc "Returns the focused sidebar aggregate."
  @spec sidebars(t()) :: Sidebars.t()
  def sidebars(%__MODULE__{sidebars: sidebars}), do: sidebars

  @doc "Returns the git status panel data, or nil."
  @spec git_status_panel(t()) :: git_status_panel() | nil
  def git_status_panel(%__MODULE__{sidebars: sidebars}), do: Sidebars.git_status_panel(sidebars)

  @doc "Replaces the Git status panel through the sidebar owner."
  @spec replace_git_status_panel(t(), git_status_panel() | nil) :: t()
  def replace_git_status_panel(%__MODULE__{} = state, nil),
    do: %{state | sidebars: Sidebars.replace_git_status(state.sidebars, nil)}

  def replace_git_status_panel(%__MODULE__{} = state, %GitStatusPanel{} = panel),
    do: %{state | sidebars: Sidebars.replace_git_status(state.sidebars, panel)}

  @doc "Returns the TUI-only git status view state, or nil."
  @spec git_status_tui_state(t()) :: git_status_tui_state() | nil
  def git_status_tui_state(%__MODULE__{sidebars: sidebars}),
    do: Sidebars.git_status_tui_state(sidebars)

  @doc "Replaces the TUI-only Git status view state."
  @spec replace_git_status_tui_state(t(), git_status_tui_state() | nil) :: t()
  def replace_git_status_tui_state(%__MODULE__{} = state, nil),
    do: %{state | sidebars: Sidebars.replace_git_status_tui(state.sidebars, nil)}

  def replace_git_status_tui_state(%__MODULE__{} = state, %TUIState{} = tui),
    do: %{state | sidebars: Sidebars.replace_git_status_tui(state.sidebars, tui)}

  @doc "Closes the Git status sidebar and its paired TUI state."
  @spec close_git_status_panel(t()) :: t()
  def close_git_status_panel(%__MODULE__{} = state),
    do: %{state | sidebars: Sidebars.close_git_status(state.sidebars)}

  @doc "Returns the active native sidebar id."
  @spec sidebar_active_id(t()) :: String.t() | nil
  def sidebar_active_id(%__MODULE__{sidebars: sidebars}), do: Sidebars.active_id(sidebars)

  @doc "Selects the active native sidebar id."
  @spec select_sidebar(t(), String.t() | nil) :: t()
  def select_sidebar(%__MODULE__{} = state, id),
    do: %{state | sidebars: Sidebars.select(state.sidebars, id)}

  @doc "Returns the BEAM Observatory lifecycle value."
  @spec observatory(t()) :: Observatory.t()
  def observatory(%__MODULE__{sidebars: sidebars}), do: Sidebars.observatory(sidebars)

  @doc "Returns true when the BEAM Observatory sidebar is visible."
  @spec observatory_visible?(t()) :: boolean()
  def observatory_visible?(%__MODULE__{} = state),
    do: state |> observatory() |> Observatory.visible?()

  @doc "Opens and selects the BEAM Observatory sidebar."
  @spec open_observatory(t(), Observatory.timer() | nil) :: t()
  def open_observatory(%__MODULE__{} = state, timer),
    do: %{state | sidebars: Sidebars.open_observatory(state.sidebars, timer)}

  @doc "Closes the BEAM Observatory sidebar."
  @spec close_observatory(t()) :: t()
  def close_observatory(%__MODULE__{} = state),
    do: %{state | sidebars: Sidebars.close_observatory(state.sidebars)}

  @doc "Expires a matching Observatory refresh token."
  @spec expire_observatory_refresh(t(), reference()) :: {:collect | :stale, t()}
  def expire_observatory_refresh(%__MODULE__{} = state, token) do
    case Sidebars.expire_observatory(state.sidebars, token) do
      {result, sidebars} -> {result, %{state | sidebars: sidebars}}
    end
  end

  @doc "Completes a matching Observatory refresh and installs the next timer."
  @spec complete_observatory_refresh(
          t(),
          reference(),
          MingaEditor.Observatory.Data.t(),
          Observatory.timer()
        ) :: {:accepted | :stale, t()}
  def complete_observatory_refresh(%__MODULE__{} = state, token, data, next_timer) do
    case Sidebars.complete_observatory(state.sidebars, token, data, next_timer) do
      {result, sidebars} -> {result, %{state | sidebars: sidebars}}
    end
  end

  @doc "Replaces Observatory data without changing refresh correlation."
  @spec replace_observatory_data(t(), MingaEditor.Observatory.Data.t() | nil) :: t()
  def replace_observatory_data(%__MODULE__{} = state, data),
    do: %{state | sidebars: Sidebars.replace_observatory_data(state.sidebars, data)}

  @doc "Shows or dismisses the Observatory process inspection."
  @spec inspect_observatory(t(), MingaEditor.Observatory.Inspection.t() | nil) :: t()
  def inspect_observatory(%__MODULE__{} = state, inspection),
    do: %{state | sidebars: Sidebars.inspect_observatory(state.sidebars, inspection)}

  # ── Tab bar ────────────────────────────────────────────────────────────────

  @doc "Returns the tab bar state, or nil."
  @spec tab_bar(t()) :: TabBar.t() | nil
  def tab_bar(%__MODULE__{tab_bar: tab_bar}), do: tab_bar

  @doc "Installs an exact tab-bar value or clears it with nil."
  @spec install_tab_bar(t(), TabBar.t() | nil) :: t()
  def install_tab_bar(%__MODULE__{} = state, nil), do: %{state | tab_bar: nil}

  def install_tab_bar(%__MODULE__{} = state, %TabBar{} = tab_bar),
    do: %{state | tab_bar: tab_bar}

  # ── Agent presentation and inline surfaces ────────────────────────────────

  @doc "Returns the focused agent-surface owner."
  @spec agent_surfaces(t()) :: AgentSurfaces.t()
  def agent_surfaces(%__MODULE__{agent_surfaces: surfaces}), do: surfaces

  @doc "Returns the agent presentation cache."
  @spec agent(t()) :: AgentState.t()
  def agent(%__MODULE__{agent_surfaces: surfaces}),
    do: AgentSurfaces.presentation(surfaces)

  @doc "Replaces the agent presentation cache."
  @spec replace_agent(t(), AgentState.t()) :: t()
  def replace_agent(%__MODULE__{} = state, %AgentState{} = agent),
    do: %{state | agent_surfaces: AgentSurfaces.replace_presentation(state.agent_surfaces, agent)}

  # ── Modal overlay ──────────────────────────────────────────────────────────

  @doc "Returns the active modal overlay value (`:none` when no modal is open)."
  @spec modal(t()) :: ModalOverlay.t()
  def modal(%__MODULE__{modal: modal}), do: modal

  @doc "Opens an exact modal value through the conflict-sticky transition."
  @spec open_modal(t(), ModalOverlay.active()) :: t()
  def open_modal(%__MODULE__{} = state, modal),
    do: %{state | modal: ModalOverlay.open(state.modal, modal)}

  @doc "Transitions to an exact modal value unconditionally."
  @spec transition_modal(t(), ModalOverlay.active()) :: t()
  def transition_modal(%__MODULE__{} = state, modal),
    do: %{state | modal: ModalOverlay.transition(state.modal, modal)}

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
  @spec put_modal_completion_trigger(t(), MingaEditor.CompletionTrigger.t(), Tab.id() | nil) ::
          t()
  def put_modal_completion_trigger(%__MODULE__{} = state, trigger, active_tab_id),
    do: %{
      state
      | modal: ModalOverlay.put_completion_trigger(state.modal, trigger, active_tab_id)
    }

  @doc "Dismisses stale completion using the now-active tab id."
  @spec dismiss_stale_modal_completion(t(), Tab.id() | nil) :: t()
  def dismiss_stale_modal_completion(%__MODULE__{} = state, active_tab_id),
    do: %{state | modal: ModalOverlay.dismiss_if_stale(state.modal, active_tab_id)}

  # ── Inline agent surfaces ──────────────────────────────────────────────────

  @doc "Returns the inline ask store."
  @spec inline_asks(t()) :: InlineAsk.store()
  def inline_asks(%__MODULE__{agent_surfaces: surfaces}), do: AgentSurfaces.asks(surfaces)

  @doc "Activates or replaces an inline ask."
  @spec activate_inline_ask(t(), InlineAsk.t()) :: t()
  def activate_inline_ask(%__MODULE__{} = state, %InlineAsk{} = ask),
    do: %{state | agent_surfaces: AgentSurfaces.activate_ask(state.agent_surfaces, ask)}

  @doc "Replaces an inline ask after a leaf transition."
  @spec replace_inline_ask(t(), InlineAsk.t()) :: t()
  def replace_inline_ask(%__MODULE__{} = state, %InlineAsk{} = ask),
    do: %{state | agent_surfaces: AgentSurfaces.replace_ask(state.agent_surfaces, ask)}

  @doc "Cancels an inline ask and returns its session pid."
  @spec cancel_inline_ask(t(), pid() | nil) :: {t(), pid() | nil}
  def cancel_inline_ask(%__MODULE__{} = state, buffer_pid) do
    {surfaces, session_pid} = AgentSurfaces.cancel_ask(state.agent_surfaces, buffer_pid)
    {%{state | agent_surfaces: surfaces}, session_pid}
  end

  @doc "Returns the inline edit store."
  @spec inline_edits(t()) :: InlineEdit.store()
  def inline_edits(%__MODULE__{agent_surfaces: surfaces}), do: AgentSurfaces.edits(surfaces)

  @doc "Activates or replaces an inline edit."
  @spec activate_inline_edit(t(), InlineEdit.t()) :: t()
  def activate_inline_edit(%__MODULE__{} = state, %InlineEdit{} = edit),
    do: %{state | agent_surfaces: AgentSurfaces.activate_edit(state.agent_surfaces, edit)}

  @doc "Replaces an inline edit after a leaf transition."
  @spec replace_inline_edit(t(), InlineEdit.t()) :: t()
  def replace_inline_edit(%__MODULE__{} = state, %InlineEdit{} = edit),
    do: %{state | agent_surfaces: AgentSurfaces.replace_edit(state.agent_surfaces, edit)}

  @doc "Cancels an inline edit and returns its session pid."
  @spec cancel_inline_edit(t(), pid() | nil) :: {t(), pid() | nil}
  def cancel_inline_edit(%__MODULE__{} = state, buffer_pid) do
    {surfaces, session_pid} = AgentSurfaces.cancel_edit(state.agent_surfaces, buffer_pid)
    {%{state | agent_surfaces: surfaces}, session_pid}
  end

  # ── Tool prompt lifecycle ──────────────────────────────────────────────────

  @doc "Returns the focused tool-prompt owner."
  @spec tool_prompts(t()) :: ToolPrompts.t()
  def tool_prompts(%__MODULE__{tool_prompts: prompts}), do: prompts

  @doc "Returns whether a tool was declined or is already queued."
  @spec tool_prompt_decided?(t(), atom()) :: boolean()
  def tool_prompt_decided?(%__MODULE__{} = state, tool_name),
    do: ToolPrompts.decided?(state.tool_prompts, tool_name)

  @doc "Queues a missing tool once."
  @spec enqueue_tool_prompt(t(), atom()) :: t()
  def enqueue_tool_prompt(%__MODULE__{} = state, tool_name),
    do: %{state | tool_prompts: ToolPrompts.enqueue(state.tool_prompts, tool_name)}

  @doc "Replaces tool-prompt decisions and pending queue atomically."
  @spec replace_tool_prompts(t(), [atom()], MapSet.t(atom())) :: t()
  def replace_tool_prompts(%__MODULE__{} = state, queue, %MapSet{} = declined)
      when is_list(queue),
      do: %{state | tool_prompts: ToolPrompts.replace(state.tool_prompts, queue, declined)}

  @doc "Advances to the next missing-tool prompt."
  @spec advance_tool_prompt(t()) :: t()
  def advance_tool_prompt(%__MODULE__{} = state),
    do: %{state | tool_prompts: ToolPrompts.advance(state.tool_prompts)}

  # ── Input lifecycle ────────────────────────────────────────────────────────

  @doc "Returns Traditional input state."
  @spec input(t()) :: InputState.t()
  def input(%__MODULE__{input: input}), do: input

  @doc "Returns the renderer-authored click-region value."
  @spec click_regions(t()) :: ClickRegions.t()
  def click_regions(%__MODULE__{input: input}), do: InputState.click_regions(input)

  @doc "Installs both click-region sets from one render."
  @spec install_click_regions(
          t(),
          [MingaEditor.Shell.Traditional.Modeline.click_region()],
          [ClickRegions.tab_bar_region()]
        ) :: t()
  def install_click_regions(%__MODULE__{} = state, modeline, tab_bar),
    do: %{state | input: InputState.install_click_regions(state.input, modeline, tab_bar)}

  @doc "Installs one already-correlated click-region value."
  @spec install_click_regions(t(), ClickRegions.t()) :: t()
  def install_click_regions(%__MODULE__{} = state, %ClickRegions{} = regions),
    do: %{state | input: InputState.install_click_regions(state.input, regions)}

  @doc "Returns the modeline command under a rendered column."
  @spec modeline_command_at(t(), non_neg_integer()) :: atom() | nil
  def modeline_command_at(%__MODULE__{input: input}, col),
    do: InputState.modeline_command_at(input, col)

  @doc "Returns the tab-bar command under a rendered cell."
  @spec tab_bar_command_at(t(), non_neg_integer(), non_neg_integer()) ::
          tab_bar_command() | nil
  def tab_bar_command_at(%__MODULE__{input: input}, row, col),
    do: InputState.tab_bar_command_at(input, row, col)

  @doc "Resets all renderer-authored click regions."
  @spec reset_click_regions(t()) :: t()
  def reset_click_regions(%__MODULE__{} = state),
    do: %{state | input: InputState.reset_click_regions(state.input)}

  @doc "Begins a new space-leader generation."
  @spec begin_space_leader(t()) :: {SpaceLeader.generation(), t()}
  def begin_space_leader(%__MODULE__{} = state) do
    {generation, input} = InputState.begin_space_leader(state.input)
    {generation, %{state | input: input}}
  end

  @doc "Records the current space-leader timer."
  @spec install_space_leader_timer(t(), SpaceLeader.generation(), reference()) :: t()
  def install_space_leader_timer(%__MODULE__{} = state, generation, timer),
    do: %{state | input: InputState.install_space_leader_timer(state.input, generation, timer)}

  @doc "Expires only the matching space-leader generation."
  @spec expire_space_leader(t(), SpaceLeader.generation()) :: {:expired | :stale, t()}
  def expire_space_leader(%__MODULE__{} = state, generation) do
    case InputState.expire_space_leader(state.input, generation) do
      {result, input} -> {result, %{state | input: input}}
    end
  end

  @doc "Returns whether the space-leader window is pending."
  @spec space_leader_pending?(t()) :: boolean()
  def space_leader_pending?(%__MODULE__{input: input}),
    do: InputState.space_leader_pending?(input)

  @doc "Returns the current space-leader timer handle."
  @spec space_leader_timer(t()) :: reference() | nil
  def space_leader_timer(%__MODULE__{input: input}), do: InputState.space_leader_timer(input)

  @doc "Resets the current space-leader window."
  @spec reset_space_leader(t()) :: t()
  def reset_space_leader(%__MODULE__{} = state),
    do: %{state | input: InputState.reset_space_leader(state.input)}
end
