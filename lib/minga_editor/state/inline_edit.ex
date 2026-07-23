defmodule MingaEditor.State.InlineEdit do
  @moduledoc """
  Ephemeral inline edit overlays keyed by buffer.

  The shared per-buffer store mechanics (`active/2`, `put/2`, `dismiss/2`, `session?/2`) and prompt-input mechanics (`append_input/2`, `backspace/1`, `scroll/2`) live in `MingaEditor.InlineOverlay.Store` and `MingaEditor.InlineOverlay.Prompt` and are reused here. This module owns only the edit-specific shape and transitions: the selection/original text, tagged proposal data, and the `:proposed` terminal state.
  """

  alias Minga.Project.FileRef
  alias MingaEditor.InlineOverlay.Prompt
  alias MingaEditor.InlineOverlay.Store

  @type proposal :: :none | {:stream, String.t()} | {:tool, String.t()}
  @type phase ::
          :input | {:running, pid(), proposal()} | {:proposed, proposal()} | {:failed, String.t()}

  @type t :: %__MODULE__{
          buffer_pid: pid(),
          file_ref: FileRef.t(),
          file_label: String.t(),
          selection_range: {non_neg_integer(), non_neg_integer()},
          original_text: String.t(),
          prompt: String.t(),
          phase: phase(),
          scroll: non_neg_integer()
        }

  @enforce_keys [:buffer_pid, :file_ref, :file_label, :selection_range, :original_text]
  defstruct buffer_pid: nil,
            file_ref: nil,
            file_label: "",
            selection_range: {0, 0},
            original_text: "",
            prompt: "",
            phase: :input,
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

  @spec active(store(), pid() | nil) :: t() | nil
  def active(store, buffer_pid), do: Store.active(store, buffer_pid, __MODULE__)

  @spec session?(store(), pid()) :: boolean()
  def session?(store, session_pid), do: Store.session?(store, session_pid, &session_pid/1)

  @spec put(store(), t()) :: store()
  def put(store, %__MODULE__{} = edit), do: Store.put(store, edit, __MODULE__)
  def put(store, _edit) when is_map(store), do: store

  @spec dismiss(store(), pid() | nil) :: {store(), pid() | nil}
  def dismiss(store, buffer_pid), do: Store.dismiss(store, buffer_pid, &session_pid/1)

  @spec append_input(t(), String.t()) :: t()
  def append_input(edit, text), do: Prompt.append_input(edit, text)

  @spec backspace(t()) :: t()
  def backspace(edit), do: Prompt.backspace(edit)

  @spec scroll(t(), integer()) :: t()
  def scroll(edit, delta), do: Prompt.scroll(edit, delta)

  @spec phase(t()) :: phase()
  def phase(%__MODULE__{phase: phase}), do: phase

  @spec input?(t()) :: boolean()
  def input?(%__MODULE__{} = edit), do: phase(edit) == :input

  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{} = edit), do: match?({:running, _session, _proposal}, phase(edit))

  @spec proposed?(t()) :: boolean()
  def proposed?(%__MODULE__{} = edit), do: match?({:proposed, _proposal}, phase(edit))

  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{} = edit), do: match?({:failed, _message}, phase(edit))

  @spec scrollable?(t()) :: boolean()
  def scrollable?(%__MODULE__{} = edit), do: proposed?(edit) or failed?(edit)

  @spec session_pid(t() | term()) :: pid() | nil
  def session_pid(%__MODULE__{phase: {:running, session_pid, _proposal}}), do: session_pid
  def session_pid(_edit), do: nil

  @spec proposal(t()) :: proposal()
  def proposal(%__MODULE__{phase: {:running, _session_pid, proposal}}), do: proposal
  def proposal(%__MODULE__{phase: {:proposed, proposal}}), do: proposal
  def proposal(%__MODULE__{}), do: :none

  @spec rewrite(t()) :: String.t()
  def rewrite(%__MODULE__{phase: {:failed, message}}), do: message
  def rewrite(%__MODULE__{} = edit), do: proposal_text(proposal(edit))

  @doc "Marks the edit as thinking."
  @spec thinking(t(), pid()) :: t()
  def thinking(%__MODULE__{} = edit, session_pid) when is_pid(session_pid),
    do: %{edit | phase: {:running, session_pid, :none}, scroll: 0}

  @doc "Appends proposed replacement text streamed by the assistant."
  @spec append_proposal(t(), String.t()) :: t()
  def append_proposal(%__MODULE__{phase: {:running, session_pid, :none}} = edit, delta)
      when is_binary(delta), do: %{edit | phase: {:running, session_pid, {:stream, delta}}}

  def append_proposal(
        %__MODULE__{phase: {:running, session_pid, {:stream, proposed}}} = edit,
        delta
      )
      when is_binary(delta),
      do: %{edit | phase: {:running, session_pid, {:stream, proposed <> delta}}}

  def append_proposal(
        %__MODULE__{phase: {:running, _session_pid, {:tool, _proposed}}} = edit,
        delta
      )
      when is_binary(delta), do: edit

  def append_proposal(%__MODULE__{} = edit, delta) when is_binary(delta), do: edit

  @doc "Installs proposed replacement text from the constrained rewrite tool."
  @spec install_proposal(t(), String.t()) :: t()
  def install_proposal(%__MODULE__{phase: {:running, session_pid, _proposal}} = edit, proposed)
      when is_binary(proposed), do: %{edit | phase: {:running, session_pid, {:tool, proposed}}}

  def install_proposal(%__MODULE__{} = edit, proposed) when is_binary(proposed), do: edit

  @doc "Marks the edit as proposed."
  @spec proposed(t()) :: t()
  def proposed(%__MODULE__{phase: {:running, _session_pid, proposal}} = edit),
    do: %{edit | phase: {:proposed, proposal}}

  def proposed(%__MODULE__{} = edit), do: edit

  @doc "Constructs a proposed streamed rewrite for direct tests."
  @spec proposed(t(), String.t()) :: t()
  def proposed(%__MODULE__{} = edit, rewrite) when is_binary(rewrite),
    do: %{edit | phase: {:proposed, {:stream, rewrite}}}

  @doc "Marks the edit as failed."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = edit, message) when is_binary(message),
    do: %{edit | phase: {:failed, message}}

  @spec proposal_text(proposal()) :: String.t()
  defp proposal_text(:none), do: ""
  defp proposal_text({:stream, text}), do: text
  defp proposal_text({:tool, text}), do: text

  @spec file_identity(FileRef.t()) :: String.t()
  defp file_identity(%FileRef{kind: :path, relative_path: path}) when is_binary(path), do: path
  defp file_identity(%FileRef{display_name: name}), do: name
end
