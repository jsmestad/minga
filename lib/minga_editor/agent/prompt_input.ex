defmodule MingaEditor.Agent.PromptInput do
  @moduledoc "Admits prompt geometry and pointer input against the exact retained prompt source."

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Mouse.Target.Text
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State
  alias MingaEditor.WindowFocus

  @type state :: State.t()

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
