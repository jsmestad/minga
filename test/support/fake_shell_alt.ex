defmodule MingaEditor.Test.FakeShellAlt do
  @moduledoc "Alternate test shell used by shell registry lifecycle tests."

  @behaviour MingaEditor.Shell
  @behaviour MingaEditor.Shell.Layout
  @behaviour MingaEditor.Shell.Chrome
  @behaviour MingaEditor.Shell.InputRouter
  @behaviour MingaEditor.Shell.BufferLifecycle
  @behaviour MingaEditor.Shell.TabQueries

  @impl true
  @spec init(keyword()) :: map()
  def init(opts), do: %{name: Keyword.get(opts, :name, :fake_alt), events: []}

  @impl true
  @spec compute_layout(map()) :: MingaEditor.Layout.t()
  def compute_layout(%{terminal_viewport: viewport}) do
    %MingaEditor.Layout{
      terminal: {0, 0, viewport.cols, viewport.rows},
      editor_area: {0, 0, viewport.cols, max(viewport.rows - 1, 1)},
      minibuffer: {max(viewport.rows - 1, 0), 0, viewport.cols, 1}
    }
  end

  @impl true
  @spec build_chrome(term(), MingaEditor.Layout.t(), map(), term()) ::
          MingaEditor.RenderPipeline.Chrome.t()
  def build_chrome(_editor_state, _layout, _scrolls, _cursor_info),
    do: %MingaEditor.RenderPipeline.Chrome{}

  @impl true
  @spec chrome_fingerprint(term()) :: term()
  def chrome_fingerprint(_editor_state), do: :fake_alt

  @impl true
  @spec async_render?(term()) :: boolean()
  def async_render?(_editor_state), do: false

  @impl true
  @spec gui_payload(term()) :: nil
  def gui_payload(_editor_state), do: nil

  @impl true
  @spec render(term()) :: term()
  def render(editor_state), do: editor_state

  @impl true
  @spec input_handlers(term()) :: %{overlay: [module()], surface: [module()]}
  def input_handlers(_editor_state), do: %{overlay: [], surface: []}

  @impl true
  @spec handle_event(map(), MingaEditor.Session.State.t(), term()) ::
          {map(), MingaEditor.Session.State.t()}
  def handle_event(shell_state, workspace, event),
    do: {%{shell_state | events: [event | Map.get(shell_state, :events, [])]}, workspace}

  @impl true
  @spec handle_gui_action(map(), MingaEditor.Session.State.t(), term()) ::
          {map(), MingaEditor.Session.State.t()}
  def handle_gui_action(shell_state, workspace, action),
    do: {%{shell_state | events: [action | Map.get(shell_state, :events, [])]}, workspace}

  @impl true
  @spec on_buffer_added(
          map(),
          MingaEditor.Session.State.t(),
          MingaEditor.Session.State.t(),
          pid(),
          atom()
        ) :: {map(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_added(shell_state, _prev_workspace, workspace, _buffer_pid, _context),
    do: {shell_state, workspace, []}

  @impl true
  @spec on_buffer_switched(map(), MingaEditor.Session.State.t()) ::
          {map(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_switched(shell_state, workspace), do: {shell_state, workspace, []}

  @impl true
  @spec on_buffer_died(map(), MingaEditor.Session.State.t(), pid()) ::
          {map(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_buffer_died(shell_state, workspace, _dead_pid), do: {shell_state, workspace, []}

  @impl true
  @spec on_agent_event(map(), MingaEditor.Session.State.t(), pid(), term()) ::
          {map(), MingaEditor.Session.State.t(), [MingaEditor.effect()]}
  def on_agent_event(shell_state, workspace, _session, _event), do: {shell_state, workspace, []}

  @impl true
  @spec active_tab(map()) :: nil
  def active_tab(_shell_state), do: nil

  @impl true
  @spec find_tab_by_buffer(map(), pid()) :: nil
  def find_tab_by_buffer(_shell_state, _pid), do: nil

  @impl true
  @spec active_tab_kind(map()) :: :none
  def active_tab_kind(_shell_state), do: :none

  @impl true
  @spec set_tab_session(map(), term(), pid() | nil) :: map()
  def set_tab_session(shell_state, _tab_id, _session_pid), do: shell_state

  @impl true
  @spec active_session(map()) :: nil
  def active_session(_shell_state), do: nil
end
