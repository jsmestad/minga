defmodule Minga.RenderModel.UI.StatusBar.Data do
  @moduledoc false

  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
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
          | :branch_delete_confirm
  @type modeline_segment ::
          {atom() | String.t(), String.t(), non_neg_integer(), non_neg_integer(), keyword(),
           atom() | nil}
  @type modeline_segments :: %{left: [modeline_segment()], right: [modeline_segment()]} | nil

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
          recording: {true, String.t()} | false | nil,
          indent: Indent.t(),
          selection: Selection.t(),
          agent: Agent.t(),
          modeline_segments: modeline_segments()
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
            recording: false,
            indent: %Indent{},
            selection: %Selection{},
            agent: %Agent{},
            modeline_segments: nil
end
