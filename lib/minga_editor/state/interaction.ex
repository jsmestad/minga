defmodule MingaEditor.State.Interaction do
  @moduledoc """
  Per-editor input configuration and transient interaction history.

  The value owns editing-model selection, isolated keymap/options services,
  and keystroke history used by input diagnostics.
  """

  alias MingaEditor.KeystrokeHistory
  alias MingaEditor.Quickfix

  @type editing_model :: :vim | :cua
  @type t :: %__MODULE__{
          editing_model: editing_model(),
          keymap_server: Minga.Keymap.server(),
          options_server: Minga.Config.Options.server(),
          project_server: GenServer.server(),
          file_tree_duplicate_backend: MingaEditor.Commands.FileTree.DuplicateBackend.t(),
          file_tree_new_file_backend: MingaEditor.Commands.FileTree.NewFileBackend.t(),
          keystroke_history: KeystrokeHistory.t(),
          queued_input_edit: MingaEditor.Agent.QueuedInputEdit.edit() | nil,
          keep_requests: :gen_server.request_id_collection() | nil,
          quickfix: Quickfix.t()
        }

  defstruct editing_model: :vim,
            keymap_server: Minga.Keymap.Active,
            options_server: Minga.Config.Options,
            project_server: Minga.Project,
            file_tree_duplicate_backend:
              {MingaEditor.Commands.FileTree.SystemDuplicateBackend, nil},
            file_tree_new_file_backend: MingaEditor.Commands.FileTree.SystemNewFileBackend,
            keystroke_history: KeystrokeHistory.new(),
            queued_input_edit: nil,
            keep_requests: nil,
            quickfix: %Quickfix{}

  @doc "Creates interaction state from startup configuration."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      editing_model: Keyword.get(opts, :editing_model, :vim),
      keymap_server: Keyword.get(opts, :keymap_server, Minga.Keymap.Active),
      options_server: Keyword.get(opts, :options_server, Minga.Config.Options),
      project_server: Keyword.get(opts, :project_server, Minga.Project),
      file_tree_duplicate_backend:
        Keyword.get(
          opts,
          :file_tree_duplicate_backend,
          {MingaEditor.Commands.FileTree.SystemDuplicateBackend, nil}
        ),
      file_tree_new_file_backend:
        Keyword.get(
          opts,
          :file_tree_new_file_backend,
          MingaEditor.Commands.FileTree.SystemNewFileBackend
        )
    }
  end

  @doc "Commits keystroke history produced by the input recorder."
  @spec accept_keystroke_history(t(), KeystrokeHistory.t()) :: t()
  def accept_keystroke_history(%__MODULE__{} = interaction, %KeystrokeHistory{} = history),
    do: %{interaction | keystroke_history: history}

  @doc "Installs the sole temporary queued-input editing buffer and its exact target."
  @spec put_queued_input_edit(t(), MingaEditor.Agent.QueuedInputEdit.edit() | nil) :: t()
  def put_queued_input_edit(%__MODULE__{} = interaction, edit),
    do: %{interaction | queued_input_edit: edit}

  @doc "Tracks exact in-file Keep responses across the editor's tabs."
  @spec put_keep_requests(t(), :gen_server.request_id_collection() | nil) :: t()
  def put_keep_requests(%__MODULE__{} = interaction, requests),
    do: %{interaction | keep_requests: requests}

  @doc "Installs the editor's shared list of locations without depending on the producing tab."
  @spec put_quickfix(t(), Quickfix.t()) :: t()
  def put_quickfix(%__MODULE__{} = interaction, %Quickfix{} = list),
    do: %{interaction | quickfix: list}
end
