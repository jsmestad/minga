defmodule Mix.Tasks.Conformance.FocusScenarios do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel
  alias Minga.RenderModel.UI
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Viewport
  alias MingaEditor.FocusOwner
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Session.State, as: Workspace
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: Shell
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Search

  @focus_opcode Minga.Protocol.Opcodes.gui_focus_owner()

  @doc "Builds shared framed focus transcripts using the production derivation and encoder."
  @spec build_all() :: [map()]
  def build_all do
    Enum.map(scenarios(), fn {name, actions} ->
      {steps, _} =
        Enum.map_reduce(
          Enum.with_index(actions, 1),
          {%EditorState{workspace: %Workspace{}}, %Caches{}},
          &build_step/2
        )

      %{
        "name" => name,
        "category" => "focus",
        "frontends" => %{"swift" => true, "go" => true},
        "description" =>
          "Committed BEAM keyboard owner through #{name}; native mechanics remain frontend-local.",
        "steps" => steps
      }
    end)
  end

  @spec build_step({{atom(), boolean()}, pos_integer()}, {EditorState.t(), Caches.t()}) ::
          {map(), {EditorState.t(), Caches.t()}}
  defp build_step({{action, keyframe?}, seq}, {state, caches}) do
    state = transition(state, action)
    caches = if keyframe?, do: %Caches{}, else: caches
    owner = FocusOwner.derive(state)
    encoded = GUI.encode(model(state, owner), caches)
    base = if keyframe?, do: 0, else: seq - 1

    {focus, chrome} =
      Enum.split_with(
        encoded.chrome_commands,
        &match?(<<@focus_opcode, _::binary>>, &1)
      )

    commands =
      [Protocol.encode_begin_frame(seq, base, 1)] ++
        focus ++ encoded.metal_commands ++ chrome ++ [Protocol.encode_commit_frame(seq)]

    step = %{
      "kind" => "framed",
      "note" => Atom.to_string(action),
      "reset_frontend" => action == :reattach,
      "payload_base64" => commands |> IO.iodata_to_binary() |> Base.encode64(),
      "command_sizes" => Enum.map(commands, &byte_size/1),
      "expect" => %{
        "focus_target" => expectation(owner),
        "last_committed" => %{"generation" => 1, "frame_seq" => seq},
        "transaction_result" => %{
          "kind" => "applied",
          "generation" => 1,
          "frame_seq" => seq
        }
      }
    }

    {step, {state, encoded.caches}}
  end

  @doc "Exposes named source transitions to the BEAM corpus oracle."
  @spec scenarios() :: [{String.t(), [{atom(), boolean()}]}]
  def scenarios do
    [
      {"picker_open_close",
       [{:editor, true}, {:picker_open, false}, {:unchanged, false}, {:picker_close, false}]},
      {"search_open_close", [{:editor, true}, {:search_open, false}, {:search_close, false}]},
      {"rename_confirm", [{:file_tree, true}, {:rename_open, false}, {:rename_confirm, false}]},
      {"rename_cancel", [{:file_tree, true}, {:rename_open, false}, {:rename_cancel, false}]},
      {"agent_toggle", [{:editor, true}, {:agent_open, false}, {:agent_close, false}]},
      {"reattach_keyframe",
       [{:editor, true}, {:picker_open, false}, {:reattach, true}, {:picker_close, false}]},
      {"hover_and_empty",
       [{:editor, true}, {:hover_open, false}, {:hover_close, false}, {:empty_state, false}]}
    ]
  end

  @doc "Applies a named source transition through the owning state APIs."
  @spec transition(EditorState.t(), atom()) :: EditorState.t()
  def transition(state, action) when action in [:unchanged, :reattach], do: state
  def transition(state, :editor), do: put_scope(state, :editor)
  def transition(state, :file_tree), do: put_scope(state, :file_tree)
  def transition(state, :agent_open), do: put_scope(state, :agent)
  def transition(state, :agent_close), do: put_scope(state, :editor)

  def transition(state, :picker_open) do
    picker = %MingaEditor.State.Picker{}
    payload = MingaEditor.State.ModalOverlay.Picker.new(picker)
    put_shell(state, Shell.open_modal(Runtime.state(state.shell_runtime), {:picker, payload}))
  end

  def transition(state, :picker_close),
    do: put_shell(state, Shell.dismiss_modal(Runtime.state(state.shell_runtime)))

  def transition(state, :search_open),
    do: put_search(state, Search.focus_gui_search(state.workspace.search, false))

  def transition(state, :search_close),
    do: put_search(state, Search.dismiss_gui_search(state.workspace.search))

  def transition(state, :rename_open) do
    entry = %{
      path: "/conformance/original.swift",
      name: "original.swift",
      dir?: false,
      depth: 0,
      last_child?: true,
      guides: []
    }

    tree = FileTree.start_rename(state.workspace.file_tree, 0, entry, 41)
    %{state | workspace: Workspace.set_file_tree(state.workspace, tree)}
  end

  def transition(state, action) when action in [:rename_confirm, :rename_cancel] do
    tree = FileTree.cancel_editing(state.workspace.file_tree)
    %{state | workspace: Workspace.set_file_tree(state.workspace, tree)}
  end

  def transition(state, :hover_open) do
    popup =
      MingaEditor.HoverPopup.new("Hover documentation", 0, 0) |> MingaEditor.HoverPopup.focus()

    shell = Shell.show_hover_popup(Runtime.state(state.shell_runtime), popup)
    put_shell(state, shell)
  end

  def transition(state, :hover_close),
    do: put_shell(state, Shell.dismiss_hover_popup(Runtime.state(state.shell_runtime)))

  def transition(state, :empty_state) do
    launchpad =
      MingaEditor.State.Launchpad.new(recents: [], session_file_count: 0, crashed?: false)

    %{state | workspace: Workspace.set_launchpad(state.workspace, launchpad)}
  end

  @doc "Names the actual FocusOwner fact without maintaining another focus derivation."
  @spec expectation(UI.FocusOwner.t()) :: map()
  def expectation(owner) do
    %{
      "surface" => Atom.to_string(owner.surface),
      "responder" => Atom.to_string(owner.responder),
      "window_id" => owner.window_id,
      "generation" => owner.generation
    }
  end

  defp put_scope(state, scope),
    do: %{state | workspace: Workspace.set_keymap_scope(state.workspace, scope)}

  defp put_search(state, search),
    do: %{state | workspace: Workspace.set_search(state.workspace, search)}

  defp put_shell(state, shell),
    do: %{state | shell_runtime: Runtime.new(Runtime.entry(state.shell_runtime), shell)}

  defp model(state, owner) do
    shell = Runtime.state(state.shell_runtime)
    picker? = MingaEditor.State.ModalOverlay.tag(shell.modal) == :picker
    editing = FileTree.editing(state.workspace.file_tree)
    tree? = state.workspace.keymap_scope == :file_tree
    {:ok, theme} = MingaEditor.UI.Theme.get(:minga_default)

    ui = %UI{
      focus_owner: owner,
      theme: MingaEditor.RenderModel.UI.ThemeBuilder.build(theme),
      picker: %UI.Picker{
        visible?: picker?,
        title: "Focus conformance",
        activation_generation: 1,
        query_generation: 1
      },
      search_state: %UI.SearchState{
        active: Search.gui_search_active?(state.workspace.search),
        session_id: 1
      },
      file_tree: tree_model(tree?, editing),
      sidebars: %UI.Sidebars{
        active_id: if(tree?, do: "file_tree", else: ""),
        sidebars: [
          %UI.Sidebars.Sidebar{
            id: "file_tree",
            display_name: "File Tree",
            semantic_kind: "file_tree",
            order: 0,
            visible?: tree?,
            focused?: tree?,
            preferred_width: 240
          }
        ]
      },
      agent_chat: %UI.AgentChat{
        visible?: state.workspace.keymap_scope == :agent,
        input_focused: state.workspace.keymap_scope == :agent
      }
    }

    RenderModel.new([window()], ui, RenderModel.Cursor.new(0, 0, :block))
  end

  defp tree_model(visible?, editing) do
    edit_model =
      if editing,
        do: %UI.FileTree.Editing{type: editing.type, text: editing.text, token: editing.token}

    %UI.FileTree{
      root_path: "/conformance",
      generation: 1,
      tree_width: 30,
      status: if(visible?, do: :ready, else: :hidden),
      focused?: visible?,
      selected_id: "/conformance/original.swift",
      rows: [
        %UI.FileTree.Row{
          id: "/conformance/original.swift",
          path: "/conformance/original.swift",
          name: "original.swift",
          icon: "",
          depth: 0,
          guides: [],
          editing: edit_model
        }
      ]
    }
  end

  defp window do
    rect = {0, 0, 80, 20}

    geometry = %PaneGeometry{
      window_id: 1,
      total_rect: rect,
      content_rect: rect,
      text_rect: rect,
      gutter_rect: {0, 0, 0, 20},
      clip_rect: rect,
      viewport: %Viewport{
        top: 0,
        left: 0,
        rows: 20,
        cols: 80,
        total_lines: 1,
        total_visual_rows: 1
      },
      gutter_metrics: %Window.GutterMetrics{line_number_width: 0, sign_col_width: 0},
      hit_regions: []
    }

    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: rect,
      rows: [
        %Window.Row{
          row_id: 1,
          row_type: :normal,
          spans: [],
          content_hash: 1,
          text: "focus replay",
          buf_line: 0
        }
      ],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      content_epoch: 1,
      accessibility_generation: 1,
      accessibility_cursor: {0, 0},
      geometry: geometry
    }
  end
end
