defmodule MingaEditor.Commands.Tutor do
  @moduledoc """
  Interactive tutorial command. Opens a writable scratch buffer with vimtutor-style
  lessons that the user edits directly to practice motions and operators.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Command
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()

  @tutor_buffer_name "*Tutor*"

  @impl Minga.Command.Provider
  @spec __commands__() :: [Command.t()]
  def __commands__ do
    [
      %Command{
        name: :tutor,
        description: "Interactive Minga tutorial",
        requires_buffer: false,
        execute: fn state -> execute(state, :tutor) end
      }
    ]
  end

  @spec execute(state(), :tutor) :: state()
  def execute(state, :tutor) do
    content = load_tutorial_content()

    case find_tutor_buffer(state) do
      nil ->
        {:ok, pid} = start_tutor_buffer(content)
        state = Commands.add_buffer(state, pid)
        EditorState.set_status(state, "Welcome to the Minga Tutorial! Follow the instructions to learn.")

      pid ->
        replace_content(pid, content)
        switch_to_buffer(state, pid)
    end
  end

  @spec load_tutorial_content() :: String.t()
  defp load_tutorial_content do
    :minga
    |> Application.app_dir("priv/tutor.txt")
    |> File.read!()
  end

  @spec start_tutor_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_tutor_buffer(content) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer,
       content: content,
       buffer_name: @tutor_buffer_name,
       buffer_type: :nofile,
       read_only: false,
       filetype: :text}
    )
  end

  @spec find_tutor_buffer(state()) :: pid() | nil
  defp find_tutor_buffer(state) do
    Enum.find(state.workspace.buffers.list, fn pid ->
      Buffer.buffer_name(pid) == @tutor_buffer_name
    end)
  catch
    :exit, _ -> nil
  end

  @spec replace_content(pid(), String.t()) :: :ok
  defp replace_content(pid, content) do
    :sys.replace_state(pid, fn s ->
      %{s | document: Document.new(content)}
    end)

    Buffer.move_to(pid, {0, 0})
  end

  @spec switch_to_buffer(state(), pid()) :: state()
  defp switch_to_buffer(state, buffer) do
    idx = Enum.find_index(state.workspace.buffers.list, &(&1 == buffer))

    state =
      if idx do
        put_in(state.workspace.buffers.active_index, idx)
        |> then(fn s -> put_in(s.workspace.buffers.active, buffer) end)
      else
        Commands.add_buffer(state, buffer)
      end

    EditorState.set_status(state, "Tutorial reset. Follow the instructions to learn!")
  end
end
