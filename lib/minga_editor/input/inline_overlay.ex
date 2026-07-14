defmodule MingaEditor.Input.InlineOverlay do
  @moduledoc """
  Shared input plumbing for inline overlays (ask and edit).

  Both overlay input handlers do the same framing work: find the overlay
  that owns the active buffer, route the key to a variant-specific key
  table, and on submit start an ephemeral agent session subscribed to the
  Editor. This module owns that shared plumbing (active lookup, store
  write-back, dismissal, submit, prompt-input guard, project root). The
  variant adapters supply a `spec` map and their own key clauses.

  The `spec` carries the variant's store accessor/setter, its state
  module, and the `session_starter` (`EphemeralSession.ask/3` or
  `EphemeralSession.rewrite/2`-shaped) used on submit. Keeping submit here
  preserves the deliberate `subscriber: self()` direct subscription for
  both variants.
  """

  import Bitwise, only: [band: 2]

  alias MingaEditor.State, as: EditorState

  @typedoc """
  Variant behaviour for an inline overlay input handler.

  * `:store` reads the variant's per-buffer overlay store off editor state.
  * `:replace` replaces one overlay through the focused surface owner.
  * `:cancel` removes one overlay through the focused surface owner.
  * `:state_module` is the variant state module (for `active/2`, `put/2`,
    `dismiss/2`, `thinking/2`, `fail/2`, `append_input/2`, `backspace/1`,
    `agent_prompt/1`).
  * `:session_starter` starts the ephemeral session
    (`(prompt, project_root, opts) -> {:ok, pid} | {:error, term}`).
  * `:fail_prefix` is the status prefix used when the session fails to start.
  """
  @type spec :: %{
          store: (EditorState.t() -> %{pid() => struct()}),
          replace: (EditorState.t(), struct() -> EditorState.t()),
          cancel: (EditorState.t(), pid() | nil -> {EditorState.t(), pid() | nil}),
          state_module: module(),
          session_starter: (String.t(), String.t(), keyword() -> {:ok, pid()} | {:error, term()}),
          fail_prefix: String.t()
        }

  @typedoc "Editor input handler state."
  @type state :: MingaEditor.Input.Handler.handler_state()

  @doc """
  Returns the active overlay for the active buffer, or `nil`.

  `nil` when there is no active buffer or no overlay for it, which lets the
  adapter return `{:passthrough, state}`.
  """
  @spec active(state(), spec()) :: struct() | nil
  def active(%{workspace: %{buffers: %{active: buffer_pid}}} = state, spec)
      when is_pid(buffer_pid) do
    spec.store.(state) |> spec.state_module.active(buffer_pid)
  end

  def active(_state, _spec), do: nil

  @doc "Writes an updated overlay back into its store on editor state."
  @spec update(state(), struct(), spec()) :: state()
  def update(state, overlay, spec), do: spec.replace.(state, overlay)

  @doc "Stops the overlay's session and removes it from its store."
  @spec dismiss(state(), struct(), spec()) :: state()
  def dismiss(state, overlay, spec) do
    MingaAgent.EphemeralSession.stop(overlay.session_pid)

    {state, _session_pid} = spec.cancel.(state, overlay.buffer_pid)
    state
  end

  @doc "Appends a printable codepoint to the prompt, honouring modifier gating."
  @spec append_printable(state(), struct(), non_neg_integer(), non_neg_integer(), spec()) ::
          state()
  def append_printable(state, overlay, codepoint, modifiers, spec) do
    if printable_text_input?(modifiers) do
      update(state, spec.state_module.append_input(overlay, <<codepoint::utf8>>), spec)
    else
      state
    end
  end

  @doc "Deletes one prompt character."
  @spec backspace(state(), struct(), spec()) :: state()
  def backspace(state, overlay, spec) do
    update(state, spec.state_module.backspace(overlay), spec)
  end

  @doc """
  Submits the overlay prompt by starting its ephemeral session.

  Empty prompts set `empty_status` and do nothing else. On success the
  overlay moves to `:thinking` with the session pid; on failure it is
  marked failed via the state module's `fail/2`.
  """
  @spec submit(state(), struct(), String.t(), spec()) :: state()
  def submit(state, %{prompt: ""}, empty_status, _spec),
    do: MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, empty_status)

  def submit(state, overlay, _empty_status, spec) do
    prompt = spec.state_module.agent_prompt(overlay)

    case spec.session_starter.(prompt, project_root(state), subscriber: self()) do
      {:ok, session_pid} ->
        update(state, spec.state_module.thinking(overlay, session_pid), spec)

      {:error, reason} ->
        update(
          state,
          spec.state_module.fail(overlay, "#{spec.fail_prefix}#{inspect(reason)}"),
          spec
        )
    end
  end

  @doc "Returns the project root for the active session."
  @spec project_root(state()) :: String.t()
  def project_root(state) do
    file_tree = EditorState.file_tree_state(state)
    file_tree.project_root || file_tree.original_root || File.cwd!()
  end

  @doc "True when the modifier bits carry no control/meta that should suppress text input."
  @spec printable_text_input?(non_neg_integer()) :: boolean()
  def printable_text_input?(modifiers) when is_integer(modifiers) do
    band(modifiers, 0x0E) == 0
  end
end
