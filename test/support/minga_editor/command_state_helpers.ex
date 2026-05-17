defmodule MingaEditor.CommandStateHelpers do
  @moduledoc """
  Lightweight helpers for command tests that need an EditorState-shaped value without an Editor GenServer.
  """

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias Minga.Mode.VisualState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Registers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @type state :: EditorState.t()
  @type register_type :: Registers.reg_type()

  @spec start_buffer(String.t(), keyword()) :: pid()
  def start_buffer(content, opts \\ []) when is_binary(content) and is_list(opts) do
    opts = Keyword.put(opts, :content, content)
    id = {:command_state_buffer, System.unique_integer([:positive])}
    buffer = ExUnit.Callbacks.start_supervised!({BufferProcess, opts}, id: id)
    BufferProcess.set_option(buffer, :clipboard, :none)
    buffer
  end

  @spec command_state(pid(), keyword()) :: state()
  def command_state(buffer, opts \\ []) when is_pid(buffer) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :normal)
    mode_state = Keyword.get(opts, :mode_state, Mode.initial_state())
    editing = VimState.transition(VimState.new(), mode, mode_state)
    buffers = Buffers.add(%Buffers{}, buffer)

    %EditorState{
      backend: Keyword.get(opts, :backend, :headless),
      port_manager: Keyword.get(opts, :port_manager, nil),
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: buffers,
        editing: editing
      }
    }
  end

  @spec with_mode(state(), Mode.mode(), Mode.state() | nil) :: state()
  def with_mode(%EditorState{} = state, mode, mode_state \\ nil) do
    EditorState.transition_mode(state, mode, mode_state)
  end

  @spec with_visual_selection(state(), {non_neg_integer(), non_neg_integer()}, :char | :line) ::
          state()
  def with_visual_selection(%EditorState{} = state, anchor, visual_type)
      when visual_type in [:char, :line] do
    with_mode(state, :visual, %VisualState{visual_anchor: anchor, visual_type: visual_type})
  end

  @spec with_register(state(), String.t(), String.t(), register_type()) :: state()
  def with_register(%EditorState{} = state, name, text, type \\ :charwise) do
    update_registers(state, &Registers.put(&1, name, text, type))
  end

  @spec with_active_register(state(), String.t()) :: state()
  def with_active_register(%EditorState{} = state, name) do
    update_registers(state, &Registers.set_active(&1, name))
  end

  @spec register_entry(state(), String.t()) :: Registers.entry() | nil
  def register_entry(%EditorState{} = state, name \\ "") do
    Registers.get(state.workspace.editing.reg, name)
  end

  @spec update_registers(state(), (Registers.t() -> Registers.t())) :: state()
  def update_registers(%EditorState{} = state, fun) when is_function(fun, 1) do
    EditorState.update_workspace(state, fn workspace ->
      WorkspaceState.update_editing(workspace, fn vim ->
        VimState.set_registers(vim, fun.(vim.reg))
      end)
    end)
  end
end
