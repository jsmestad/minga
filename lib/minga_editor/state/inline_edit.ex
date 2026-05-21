defmodule MingaEditor.State.InlineEdit do
  @moduledoc """
  Ephemeral inline edit overlays keyed by buffer.
  """

  alias Minga.Project.FileRef

  @type status :: :input | :thinking | :proposed | :error
  @type proposal_source :: :stream | :tool | nil

  @type t :: %__MODULE__{
          buffer_pid: pid(),
          file_ref: FileRef.t(),
          file_label: String.t(),
          selection_range: {non_neg_integer(), non_neg_integer()},
          original_text: String.t(),
          prompt: String.t(),
          proposed_rewrite: String.t(),
          proposal_source: proposal_source(),
          status: status(),
          session_pid: pid() | nil,
          scroll: non_neg_integer()
        }

  @enforce_keys [:buffer_pid, :file_ref, :file_label, :selection_range, :original_text]
  defstruct buffer_pid: nil,
            file_ref: nil,
            file_label: "",
            selection_range: {0, 0},
            original_text: "",
            prompt: "",
            proposed_rewrite: "",
            proposal_source: nil,
            status: :input,
            session_pid: nil,
            scroll: 0

  @type store :: %{pid() => t()}

  @doc "Creates a new inline edit for a selected line range."
  @spec new(pid(), FileRef.t(), String.t(), {non_neg_integer(), non_neg_integer()}, String.t()) ::
          t()
  def new(buffer_pid, %FileRef{} = file_ref, file_label, {first, last}, original_text)
      when is_pid(buffer_pid) and is_binary(file_label) and is_integer(first) and is_integer(last) and
             first >= 0 and last >= first and is_binary(original_text) do
    %__MODULE__{
      buffer_pid: buffer_pid,
      file_ref: file_ref,
      file_label: file_label,
      selection_range: {first, last},
      original_text: original_text
    }
  end

  @doc "Returns the prompt header."
  @spec header(t()) :: String.t()
  def header(%__MODULE__{selection_range: {first, last}}) do
    "Rewrite lines #{first + 1}–#{last + 1}. How?"
  end

  @doc "Builds the constrained rewrite prompt."
  @spec agent_prompt(t()) :: String.t()
  def agent_prompt(%__MODULE__{} = edit) do
    """
    You are producing a single inline rewrite inside Minga. Return only the replacement text for the selected lines. Do not edit files.

    #{header(edit)}
    File: #{file_identity(edit.file_ref)}

    Original text:
    #{edit.original_text}

    Instruction:
    #{edit.prompt}
    """
  end

  @doc "Returns the active edit for a buffer."
  @spec active(store(), pid() | nil) :: t() | nil
  def active(store, buffer_pid) when is_map(store) and is_pid(buffer_pid),
    do: Map.get(store, buffer_pid)

  def active(_store, _buffer_pid), do: nil

  @doc "Returns true when the given session pid belongs to an inline edit."
  @spec session?(store(), pid()) :: boolean()
  def session?(store, session_pid) when is_map(store) and is_pid(session_pid) do
    Enum.any?(store, fn {_buffer, edit} -> edit.session_pid == session_pid end)
  end

  @doc "Opens or replaces an edit for its buffer."
  @spec put(store(), t()) :: store()
  def put(store, %__MODULE__{buffer_pid: buffer_pid} = edit) when is_map(store),
    do: Map.put(store, buffer_pid, edit)

  @doc "Dismisses the edit for a buffer."
  @spec dismiss(store(), pid() | nil) :: {store(), pid() | nil}
  def dismiss(store, buffer_pid) when is_map(store) and is_pid(buffer_pid) do
    {edit, store} = Map.pop(store, buffer_pid)
    {store, if(edit, do: edit.session_pid, else: nil)}
  end

  def dismiss(store, _buffer_pid), do: {store, nil}

  @doc "Appends prompt input."
  @spec append_input(t(), String.t()) :: t()
  def append_input(%__MODULE__{status: :input, prompt: prompt} = edit, text) when is_binary(text),
    do: %{edit | prompt: prompt <> text}

  def append_input(%__MODULE__{} = edit, _text), do: edit

  @doc "Deletes one prompt character."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{status: :input, prompt: prompt} = edit) do
    %{edit | prompt: prompt |> String.graphemes() |> Enum.drop(-1) |> Enum.join()}
  end

  def backspace(%__MODULE__{} = edit), do: edit

  @doc "Marks the edit as thinking."
  @spec thinking(t(), pid()) :: t()
  def thinking(%__MODULE__{} = edit, session_pid) when is_pid(session_pid),
    do: %{
      edit
      | status: :thinking,
        session_pid: session_pid,
        proposed_rewrite: "",
        proposal_source: nil,
        scroll: 0
    }

  @doc "Refreshes the visible thinking status."
  @spec mark_thinking(t()) :: t()
  def mark_thinking(%__MODULE__{} = edit), do: %{edit | status: :thinking}

  @doc "Appends proposed replacement text streamed by the assistant."
  @spec append_proposal(t(), String.t()) :: t()
  def append_proposal(%__MODULE__{proposal_source: :tool} = edit, delta) when is_binary(delta),
    do: edit

  def append_proposal(%__MODULE__{proposed_rewrite: proposed} = edit, delta)
      when is_binary(delta),
      do: %{edit | proposed_rewrite: proposed <> delta, proposal_source: :stream}

  @doc "Replaces the proposed replacement text from the constrained rewrite tool."
  @spec set_proposal(t(), String.t()) :: t()
  def set_proposal(%__MODULE__{} = edit, proposed) when is_binary(proposed),
    do: %{edit | proposed_rewrite: proposed, proposal_source: :tool}

  @doc "Marks the edit as proposed."
  @spec proposed(t()) :: t()
  def proposed(%__MODULE__{} = edit), do: %{edit | status: :proposed, session_pid: nil}

  @doc "Scrolls diff text within the bounded overlay."
  @spec scroll(t(), integer()) :: t()
  def scroll(%__MODULE__{scroll: current} = edit, delta) when is_integer(delta),
    do: %{edit | scroll: max(current + delta, 0)}

  @doc "Marks the edit as failed."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = edit, message) when is_binary(message),
    do: %{edit | status: :error, proposed_rewrite: message, session_pid: nil}

  @spec file_identity(FileRef.t()) :: String.t()
  defp file_identity(%FileRef{kind: :path, relative_path: path}) when is_binary(path), do: path
  defp file_identity(%FileRef{display_name: name}), do: name
end
