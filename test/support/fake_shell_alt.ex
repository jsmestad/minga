defmodule MingaEditor.Test.FakeShellAlt do
  @moduledoc "Alternate test shell used by shell registry lifecycle tests."

  @behaviour MingaEditor.Shell

  @impl true
  @spec init(keyword()) :: map()
  def init(opts) do
    send(self(), {:fake_shell_alt_initialized, self()})
    %{name: Keyword.get(opts, :name, :fake_alt), events: [], tab_bar: nil}
  end

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
  @spec blur_bottom_panel(map()) :: map()
  def blur_bottom_panel(shell_state) do
    Map.update(shell_state, :events, [:bottom_panel_blurred], &[:bottom_panel_blurred | &1])
  end

  @impl true
  @spec handle_event(map(), MingaEditor.Session.State.t(), term()) ::
          {map(), MingaEditor.Session.State.t()}
  def handle_event(_shell_state, workspace, {:replace_test_state, replacement})
      when is_map(replacement),
      do: {replacement, workspace}

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
        ) :: {map(), MingaEditor.Session.State.t()}
  def on_buffer_added(shell_state, _prev_workspace, workspace, _buffer_pid, _context),
    do: {shell_state, workspace}

  @impl true
  @spec on_buffer_switched(map(), MingaEditor.Session.State.t()) ::
          {map(), MingaEditor.Session.State.t()}
  def on_buffer_switched(shell_state, workspace), do: {shell_state, workspace}

  @impl true
  @spec on_buffer_died(map(), MingaEditor.Session.State.t(), pid()) ::
          {map(), MingaEditor.Session.State.t()}
  def on_buffer_died(shell_state, workspace, _dead_pid), do: {shell_state, workspace}

  @impl true
  @spec on_agent_event(map(), MingaEditor.Session.State.t(), pid(), term()) ::
          {map(), MingaEditor.Session.State.t()}
  def on_agent_event(shell_state, workspace, _session, _event), do: {shell_state, workspace}

  @impl true
  @spec handle_agent_session_restarted(map(), pid(), pid(), term()) :: {map(), boolean()}
  def handle_agent_session_restarted(%{session: old_pid} = shell_state, old_pid, new_pid, _reason) do
    {Map.put(shell_state, :session, new_pid), true}
  end

  def handle_agent_session_restarted(shell_state, _old_pid, _new_pid, _reason),
    do: {shell_state, false}

  @impl true
  @spec handle_agent_session_down(map(), pid(), term()) :: {map(), boolean()}
  def handle_agent_session_down(%{session: session} = shell_state, session, _reason),
    do: {Map.put(shell_state, :session_down?, true), true}

  def handle_agent_session_down(shell_state, _session, _reason), do: {shell_state, false}

  @impl true
  @spec handle_remote_session_disconnected(map(), pid()) :: {map(), boolean()}
  def handle_remote_session_disconnected(%{session: session} = shell_state, session),
    do: {Map.put(shell_state, :remote_disconnected?, true), true}

  def handle_remote_session_disconnected(shell_state, _session), do: {shell_state, false}

  @impl true
  @spec sync_agent_status(map(), pid(), atom()) :: map()
  def sync_agent_status(%{session: session} = shell_state, session, status),
    do: Map.put(shell_state, :synced_agent_status, status)

  def sync_agent_status(shell_state, _session, _status), do: shell_state

  @spec drop_feature_state_source(map(), MingaEditor.FeatureState.source()) :: map()
  def drop_feature_state_source(%{contexts: contexts} = shell_state, source)
      when is_list(contexts) do
    contexts = Enum.map(contexts, &drop_context_feature_source(&1, source))
    %{shell_state | contexts: contexts}
  end

  def drop_feature_state_source(shell_state, _source), do: shell_state

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
  @spec active_session(map()) :: pid() | nil
  def active_session(%{session: session}) when is_pid(session), do: session
  def active_session(_shell_state), do: nil

  @spec drop_context_feature_source(
          MingaEditor.State.Tab.Context.t(),
          MingaEditor.FeatureState.source()
        ) :: MingaEditor.State.Tab.Context.t()
  defp drop_context_feature_source(context, source) do
    %MingaEditor.Session.State{viewport: MingaEditor.Viewport.new(1, 1)}
    |> MingaEditor.Session.State.restore_tab_context(context)
    |> MingaEditor.Session.State.drop_feature_state_source(source)
    |> MingaEditor.Session.State.to_tab_context()
  end
end
