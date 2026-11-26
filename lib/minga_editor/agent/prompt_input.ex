defmodule MingaEditor.Agent.PromptInput do
  @moduledoc "Admits prompt geometry and pointer input against the exact retained prompt source."

  alias Minga.Buffer
  alias MingaEditor.Agent.DraftSave
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Mouse.Target.Text
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Windows
  alias MingaEditor.WindowFocus

  @type state :: State.t()
  @type submission_owner :: {non_neg_integer(), pid(), String.t()}

  @doc "Names the workspace and conversation that own a displayed or live composer."
  @spec submission_owner({non_neg_integer(), pid()} | nil, UIState.t()) ::
          submission_owner() | nil
  def submission_owner({workspace, session}, %UIState{
        connection: %{target: %{session: session, session_id: record}}
      })
      when is_pid(session) and is_binary(record),
      do: {workspace, session, record}

  def submission_owner(_scope, _ui), do: nil

  @doc "Supplies one input's displayed attachment offer to the existing command path."
  @spec with_offer(state(), pos_integer() | nil, (state() -> state())) :: state()
  def with_offer(state, offer, dispatch) do
    next = dispatch.(%{state | frontend: Frontend.composer_input(state.frontend, offer)})
    %{next | frontend: Frontend.composer_input(next.frontend, nil)}
  end

  @doc "Admits pointer Send only against the active composer's displayed content and attachment offer."
  @spec submit_displayed(state(), pos_integer(), pos_integer() | nil, (state() -> state())) ::
          state()
  def submit_displayed(state, generation, offer, dispatch) do
    agent = TraditionalState.agent(state.shell_runtime.state)

    if AgentState.busy?(agent) or agent.continue_target != nil do
      stale_submission(state)
    else
      with_displayed_draft(state, generation, offer, fn state ->
        next =
          dispatch.(%{state | frontend: Frontend.composer_input(state.frontend, offer, true)})

        %{next | frontend: Frontend.composer_input(next.frontend, nil)}
      end)
    end
  end

  @doc "Admits a queue control only with the prompt and attachment offer rendered with it."
  @spec queue_displayed(state(), pos_integer(), pos_integer() | nil, (state() -> state())) ::
          state()
  def queue_displayed(state, generation, offer, dispatch) do
    with_displayed_draft(state, generation, offer, &with_offer(&1, offer, dispatch))
  end

  @spec with_displayed_draft(state(), pos_integer(), pos_integer() | nil, (state() -> state())) ::
          state()
  defp with_displayed_draft(state, generation, offer, dispatch) do
    with reader when reader != nil <- state.render.text_interaction_reader,
         {:ok, {buffer, version, owner}} <-
           Reader.prompt_source(reader, 65_534, generation),
         ^buffer <- state.workspace.agent_ui.panel.prompt_buffer,
         ^owner <-
           submission_owner(Runtime.review_scope(state.shell_runtime), state.workspace.agent_ui),
         %{content: {:agent_chat, :semantic}} <- Windows.active_struct(state.workspace.windows),
         ^offer <- DraftSave.attachment_offer(state.workspace.agent_ui.draft_save),
         {:ok, ^version} <- prompt_version(buffer) do
      dispatch.(state)
    else
      _stale -> stale_submission(state)
    end
  end

  @spec prompt_version(pid()) :: {:ok, non_neg_integer()} | :unavailable
  defp prompt_version(buffer) do
    {:ok, Buffer.version(buffer)}
  catch
    :exit, _reason -> :unavailable
  end

  @spec stale_submission(state()) :: state()
  defp stale_submission(state),
    do: NoticeWorkflow.publish(state, "The draft changed. Review it and send again.")

  @spec fit(state(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) :: state()
  def fit(state, window_id, generation, columns, rows)
      when columns > 0 and columns <= 0xFFFF and rows > 0 and rows <= 0xFFFF do
    with {:ok, panel} <- admit(state, window_id, generation, :fit),
         true <- fits_resource_policy?(state, rows) do
      install_panel(state, Panel.fit_prompt(panel, columns, rows))
    else
      _rejected -> state
    end
  end

  def fit(state, _window_id, _generation, _columns, _rows), do: state

  @spec scroll(state(), pos_integer(), pos_integer(), integer()) :: state()
  def scroll(state, window_id, generation, delta) do
    case admit(state, window_id, generation, :scroll) do
      {:ok, _panel} -> scroll_current(state, delta)
      {:error, _reason} -> state
    end
  end

  @doc "Scrolls a previously resolved prompt drag without moving its source cursor."
  @spec scroll_current(state(), integer()) :: state()
  def scroll_current(state, 0), do: state

  def scroll_current(state, delta) do
    panel = state.workspace.agent_ui.panel

    projection =
      PromptProjection.build(panel, fallback_columns(state),
        oracle: Capabilities.width_oracle(state.frontend.capabilities)
      )

    top =
      max(0, min(projection.scroll + delta, length(projection.rows) - projection.visible_rows))

    marker = {projection.version, projection.cursor}

    install_panel(
      state,
      Panel.scroll_prompt(panel, marker, PromptProjection.anchor(projection, top))
    )
  catch
    :exit, _reason -> state
  end

  @spec follow_cursor(state()) :: state()
  def follow_cursor(state),
    do: install_panel(state, Panel.follow_prompt_cursor(state.workspace.agent_ui.panel))

  @doc "Routes a focused prompt command through the modal prompt buffer scope."
  @spec command(state(), (state() -> state())) :: state()
  def command(%{workspace: %{agent_ui: %{panel: %{input_focused: true}}}} = state, operation),
    do: MingaEditor.Input.AgentPanel.with_prompt_buffer(state, operation)

  def command(state, operation), do: operation.(state)

  @doc """
  Settles the editing mode after a plain click inside the composer.

  The click keeps the composer's mode, as in Vim: Insert stays Insert so typing continues where the user clicked. Every other mode collapses to Normal, as a plain click does anywhere else. Both the GUI text-event path and the terminal mouse path apply this one rule.
  """
  @spec settle_mode_after_click(state()) :: state()
  def settle_mode_after_click(%State{workspace: %{editing: %{mode: :insert}}} = state), do: state

  def settle_mode_after_click(%State{} = state),
    do: %{state | workspace: SessionState.transition_mode(state.workspace, :normal)}

  @doc "Focuses the actual agent pane while retaining the exact prompt-buffer owner."
  @spec focus(state(), Text.t()) :: {:ok, state()} | {:error, atom()}
  def focus(state, %Text{window_id: 65_534, buffer: buffer}), do: focus_owner(state, buffer)

  def focus(_state, %Text{}), do: {:error, :target_mismatch}

  @doc "Focuses the prompt named by its exact active source presentation, without a row hit."
  @spec focus_presentation(state(), pos_integer(), pos_integer()) :: state()
  def focus_presentation(state, window_id, generation) do
    with {:ok, panel} <- admit(state, window_id, generation, :focus),
         {:ok, focused} <- focus_owner(state, panel.prompt_buffer) do
      focused
    else
      {:error, _reason} -> state
    end
  end

  @spec focus_owner(state(), pid()) :: {:ok, state()} | {:error, atom()}
  defp focus_owner(state, buffer) do
    with true <- state.workspace.agent_ui.panel.prompt_buffer == buffer,
         {:ok, id} <- agent_window(state),
         {:ok, state} <- WindowFocus.focus_result(state, id) do
      state = MingaEditor.Commands.FileTree.leave_focus(state)
      state = %{state | workspace: SessionState.set_keymap_scope(state.workspace, :agent)}
      ui = UIState.set_input_focused(state.workspace.agent_ui, true)
      {:ok, Workflow.install_agent_ui(state, ui)}
    else
      false -> {:error, :target_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @spec current_source?(state(), Text.t()) :: boolean()
  def current_source?(state, %Text{window_id: 65_534, buffer: buffer}),
    do:
      state.workspace.agent_ui.panel.prompt_buffer == buffer and
        match?({:ok, _id}, agent_window(state))

  def current_source?(_state, %Text{}), do: false

  @spec admit(state(), pos_integer(), pos_integer(), :fit | :scroll | :focus) ::
          {:ok, Panel.t()} | {:error, atom()}
  defp admit(state, 65_534, generation, action) do
    panel = state.workspace.agent_ui.panel

    with reader when reader != nil <- state.render.text_interaction_reader,
         {:ok, {owner, _version}} <- source_for_action(reader, generation, action),
         true <- owner == panel.prompt_buffer,
         {:ok, _id} <- agent_window(state) do
      {:ok, panel}
    else
      _rejected -> {:error, :stale_prompt}
    end
  end

  defp admit(_state, _window_id, _generation, _action), do: {:error, :target_mismatch}

  @spec source_for_action(Reader.t(), pos_integer(), :fit | :scroll | :focus) ::
          {:ok, {pid(), non_neg_integer()}} | {:error, atom()}
  defp source_for_action(reader, generation, :fit),
    do: Reader.retained_source(reader, 65_534, generation)

  defp source_for_action(reader, generation, action) when action in [:scroll, :focus],
    do: Reader.source(reader, 65_534, generation)

  @spec agent_window(state()) :: {:ok, pos_integer()} | {:error, :target_mismatch}
  defp agent_window(state) do
    case MingaEditor.Session.State.find_agent_chat_window(state.workspace) do
      {id, %{content: {:agent_chat, _session}}} -> {:ok, id}
      _other_surface -> {:error, :target_mismatch}
    end
  end

  @spec install_panel(state(), Panel.t()) :: state()
  defp install_panel(state, panel),
    do: Workflow.install_agent_ui(state, UIState.replace_panel(state.workspace.agent_ui, panel))

  @spec fits_resource_policy?(state(), pos_integer()) :: boolean()
  defp fits_resource_policy?(state, rows) do
    policy = state.frontend.capabilities.resource_policy

    not MingaEditor.Frontend.ResourcePolicy.advertised?(policy, :window_rows) or
      min(rows, 8) <= policy.max_window_rows
  end

  @spec fallback_columns(state()) :: pos_integer()
  defp fallback_columns(state) do
    case state.workspace.agent_ui.panel.prompt_viewport.fit do
      {columns, _rows} ->
        columns

      nil ->
        layout = MingaEditor.Layout.get(state).window_layouts[state.workspace.windows.active]
        {_row, _col, columns, _height} = MingaEditor.Layout.add_sidebar(layout).content

        MingaEditor.Agent.View.PromptRenderer.input_inner_width(
          MingaEditor.Agent.View.PromptRenderer.input_box_width(columns)
        )
    end
  end
end
