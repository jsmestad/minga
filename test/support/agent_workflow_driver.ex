defmodule Minga.Test.AgentWorkflowDriver do
  @moduledoc """
  Public-surface driver for agent workflow integration tests.

  Helpers in this module use editor key input and rendered agent chat models
  instead of mutating editor internals. Tests may still inspect the resulting
  editor state or render model as assertions, but setup and actions should go
  through the same surfaces a real frontend or user would use.
  """

  import ExUnit.Assertions

  alias Minga.RenderModel.UI.AgentChat
  alias Minga.Test.EditorCase
  alias MingaAgent.Session
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderModel.UI.AgentChatBuilder

  @ctrl MingaEditor.Input.mod_ctrl()

  @type editor_ctx :: EditorCase.editor_ctx()

  @doc "Opens the agent view through the default key binding and waits for a session."
  @spec open_agent_view(editor_ctx()) :: map()
  def open_agent_view(ctx) do
    EditorCase.send_keys_sync(ctx, "<SPC>aa")

    EditorCase.wait_until(
      ctx,
      fn state ->
        session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

        state.workspace.keymap_scope == :agent and is_pid(session) and
          is_pid(Session.get_provider(session))
      end,
      message: "expected SPC a a to open an agent view with a ready provider"
    )
  end

  @doc "Focuses the agent prompt through normal agent-mode input."
  @spec focus_prompt(editor_ctx()) :: map()
  def focus_prompt(ctx) do
    current = EditorCase.editor_state(ctx)

    state =
      if current.workspace.agent_ui.panel.input_focused do
        current
      else
        EditorCase.send_key_sync(ctx, ?i, 0)
      end

    assert state.workspace.agent_ui.panel.input_focused
    state
  end

  @doc "Types a prompt into the focused agent input and submits it with Enter."
  @spec submit_prompt(editor_ctx(), String.t()) :: map()
  def submit_prompt(ctx, text) when is_binary(text) do
    focus_prompt(ctx)
    EditorCase.send_keys_sync(ctx, text)
    EditorCase.send_key_sync(ctx, 13, 0)
  end

  @doc "Queues a follow-up during an active turn using Ctrl-Enter."
  @spec queue_follow_up(editor_ctx(), String.t()) :: map()
  def queue_follow_up(ctx, text) when is_binary(text) do
    focus_prompt(ctx)
    EditorCase.send_keys_sync(ctx, text)
    EditorCase.send_key_sync(ctx, 13, @ctrl)
  end

  @doc "Interrupts the active agent turn using the agent prompt Ctrl-C binding."
  @spec interrupt_turn(editor_ctx()) :: map()
  def interrupt_turn(ctx), do: EditorCase.send_key_sync(ctx, ?c, @ctrl)

  @doc "Denies the visible pending tool approval through the agent approval key handler."
  @spec deny_tool(editor_ctx()) :: map()
  def deny_tool(ctx), do: EditorCase.send_key_sync(ctx, ?n, 0)

  @doc "Approves the visible pending tool approval through the agent approval key handler."
  @spec approve_tool(editor_ctx()) :: map()
  def approve_tool(ctx), do: EditorCase.send_key_sync(ctx, ?y, 0)

  @doc "Trusts the visible pending tool approval for the current turn."
  @spec trust_tool_turn(editor_ctx()) :: map()
  def trust_tool_turn(ctx), do: EditorCase.send_key_sync(ctx, ?t, 0)

  @doc "Builds the visible agent chat render model from the current editor state."
  @spec chat_model(map()) :: AgentChat.t()
  def chat_model(state) do
    state
    |> Context.from_editor_state()
    |> AgentChatBuilder.build()
  end

  @doc "Waits until the visible agent chat model satisfies `predicate`."
  @spec wait_for_chat_model(editor_ctx(), (AgentChat.t() -> boolean()), String.t()) ::
          AgentChat.t()
  def wait_for_chat_model(ctx, predicate, message) when is_function(predicate, 1) do
    state =
      EditorCase.wait_until(
        ctx,
        fn state -> state |> chat_model() |> predicate.() end,
        max_attempts: 50,
        interval_ms: 10,
        message: message
      )

    chat_model(state)
  end
end
