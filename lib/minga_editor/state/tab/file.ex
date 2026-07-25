defmodule MingaEditor.State.Tab.File do
  @moduledoc "File-tab payload owned by `MingaEditor.State.Tab`."
  defstruct file_ref: nil
  @type t :: %__MODULE__{file_ref: Minga.Project.FileRef.t() | nil}
end
