defmodule MingaEditor.Shell.BufferMetadata do
  @moduledoc """
  Inert buffer identity prepared before shell lifecycle calculation.

  Shell owner transitions consume this value without reading a buffer process,
  logging, or performing persistence. Workflows are responsible for deriving
  the metadata while the process is live.
  """

  alias Minga.Project.FileRef

  @type t :: %__MODULE__{
          buffer_pid: pid(),
          context: MingaEditor.Shell.buffer_add_context(),
          label: String.t(),
          path: String.t() | nil,
          file_ref: FileRef.t()
        }

  @enforce_keys [:buffer_pid, :context, :label, :file_ref]
  defstruct buffer_pid: nil,
            context: :open,
            label: "[no file]",
            path: nil,
            file_ref: nil

  @doc "Builds immutable metadata from values already resolved by a workflow."
  @spec new(
          pid(),
          MingaEditor.Shell.buffer_add_context(),
          String.t(),
          String.t() | nil,
          FileRef.t()
        ) ::
          t()
  def new(buffer_pid, context, label, path, %FileRef{} = file_ref)
      when is_pid(buffer_pid) and context in [:open, :preview] and is_binary(label) and
             (is_binary(path) or is_nil(path)) do
    %__MODULE__{
      buffer_pid: buffer_pid,
      context: context,
      label: label,
      path: path,
      file_ref: file_ref
    }
  end
end
