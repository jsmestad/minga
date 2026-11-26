defmodule Minga.RenderModel.UI.StatusBar.Data do
  @moduledoc false

  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Segment
  alias Minga.RenderModel.UI.StatusBar.Selection

  @type mode ::
          :normal
          | :insert
          | :visual
          | :visual_line
          | :visual_block
          | :operator_pending
          | :command
          | :eval
          | :replace
          | :search
          | :search_prompt
          | :substitute_confirm
          | :extension_confirm
          | :tool_confirm
          | :delete_confirm
  @type modeline_segments :: %{left: [Segment.t()], right: [Segment.t()]} | nil

  @type t :: %__MODULE__{
          mode: mode(),
          safe_mode?: boolean(),
          dirty?: boolean(),
          cursor: Cursor.t(),
          diagnostics: Diagnostics.t(),
          language: Language.t(),
          git: Git.t(),
          file: File.t(),
          message: String.t() | nil,
          message_actions: [Minga.RenderModel.UI.EmptyList.Action.t()],
          recording: {true, String.t()} | false | nil,
          indent: Indent.t(),
          selection: Selection.t(),
          agent: Agent.t(),
          modeline_segments: modeline_segments(),
          pending_keys: String.t(),
          needs_you_count: non_neg_integer()
        }

  defstruct mode: :normal,
            safe_mode?: false,
            dirty?: false,
            cursor: %Cursor{},
            diagnostics: %Diagnostics{},
            language: %Language{},
            git: %Git{},
            file: %File{},
            message: nil,
            message_actions: [],
            recording: false,
            indent: %Indent{},
            selection: %Selection{},
            agent: %Agent{},
            modeline_segments: nil,
            pending_keys: "",
            # How many tasks need you: the same count as the modeline's needs-you segment and the tasks drawer.
            needs_you_count: 0
end
