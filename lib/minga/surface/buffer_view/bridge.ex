defmodule Minga.Surface.BufferView.Bridge do
  @moduledoc """
  Temporary bridge between `EditorState` and `BufferView.State`.

  During Phase 1 of the Surface extraction, the Editor still owns all
  state fields. This module copies the relevant fields into a
  `BufferView.State` struct before each surface call, and writes the
  results back to `EditorState` afterward.

  This dual-ownership is scaffolding. It goes away in Phase 2 when
  `EditorState` shrinks and surfaces own their state directly.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Surface.BufferView.State, as: BVState
  alias Minga.Surface.BufferView.State.VimState

  @doc """
  Extracts a `BufferView.State` from the current `EditorState`.

  Copies all buffer-view-related fields into the BufferView struct,
  including the vim editing model sub-state.
  """
  @spec from_editor_state(EditorState.t()) :: BVState.t()
  def from_editor_state(%EditorState{} = es) do
    %BVState{
      buffers: es.buffers,
      windows: es.windows,
      file_tree: es.file_tree,
      viewport: es.viewport,
      mouse: es.mouse,
      highlight: es.highlight,
      lsp: es.lsp,
      completion: es.completion,
      completion_trigger: es.completion_trigger,
      git_buffers: es.git_buffers,
      injection_ranges: es.injection_ranges,
      search: es.search,
      pending_conflict: es.pending_conflict,
      editing: %VimState{
        mode: es.mode,
        mode_state: es.mode_state,
        reg: es.reg,
        marks: es.marks,
        last_jump_pos: es.last_jump_pos,
        last_find_char: es.last_find_char,
        change_recorder: es.change_recorder,
        macro_recorder: es.macro_recorder
      }
    }
  end

  @doc """
  Writes `BufferView.State` fields back onto the `EditorState`.

  Only overwrites the fields that BufferView owns. Agent-related fields,
  shared infrastructure (port_manager, theme, tab_bar, etc.), and
  transient fields (render_timer, layout) are untouched.
  """
  @spec to_editor_state(EditorState.t(), BVState.t()) :: EditorState.t()
  def to_editor_state(%EditorState{} = es, %BVState{editing: %VimState{} = vim} = bv) do
    %{
      es
      | buffers: bv.buffers,
        windows: bv.windows,
        file_tree: bv.file_tree,
        viewport: bv.viewport,
        mouse: bv.mouse,
        highlight: bv.highlight,
        lsp: bv.lsp,
        completion: bv.completion,
        completion_trigger: bv.completion_trigger,
        git_buffers: bv.git_buffers,
        injection_ranges: bv.injection_ranges,
        search: bv.search,
        pending_conflict: bv.pending_conflict,
        mode: vim.mode,
        mode_state: vim.mode_state,
        reg: vim.reg,
        marks: vim.marks,
        last_jump_pos: vim.last_jump_pos,
        last_find_char: vim.last_find_char,
        change_recorder: vim.change_recorder,
        macro_recorder: vim.macro_recorder
    }
  end
end
