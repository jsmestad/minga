defmodule MingaEditor.UI.Picker.FileAttachmentSource do
  @moduledoc "Captures a selected project file before choosing the Agent draft that receives it."
  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Project
  alias Minga.Project.WorkspaceSnapshot
  alias Minga.SecureFile
  alias MingaAgent.DraftAttachment
  alias MingaEditor.PickerUI
  alias MingaEditor.State

  alias MingaEditor.UI.Picker.{
    Context,
    FileSource,
    FindFileSession,
    Item,
    ProjectFileCandidate,
    SelectionAttachmentTargetSource,
    Source
  }

  @typep origin :: {non_neg_integer(), MingaEditor.Agent.DraftSave.target()} | nil

  @doc "Opens the project file selector, optionally bound to the invoking Agent draft."
  @spec open(State.t(), origin()) :: State.t()
  def open(state, origin \\ nil) do
    context =
      case Project.snapshot(Project) do
        %WorkspaceSnapshot{} = workspace ->
          session = FindFileSession.new(File.cwd!(), Path.expand("~"), workspace)
          FindFileSession.project_context(session)

        nil ->
          %{project_root: nil}
      end

    PickerUI.open(state, __MODULE__, Map.put(context, :origin, origin))
  catch
    :exit, _reason ->
      PickerUI.open(state, __MODULE__, %{project_error: "Project service is unavailable."})
  end

  @doc "Returns the captured project activation for either picker stage."
  @spec fetch_identity(Context.t()) ::
          {:project_activation, WorkspaceSnapshot.activation_id()} | nil
  def fetch_identity(%Context{
        picker_ui: %{context: %{file: %ProjectFileCandidate{activation_id: id}}}
      })
      when is_integer(id),
      do: {:project_activation, id}

  def fetch_identity(context), do: FileSource.fetch_identity(context)

  @doc "Refreshes inventory only for the project that launched the file list."
  @spec refresh_inventory?(map() | nil, String.t() | nil) :: boolean()
  def refresh_inventory?(
        %{
          find_file_session: %FindFileSession{
            project_root: %{path: root},
            project_activation_id: id
          }
        },
        root
      ),
      do: FileSource.current_fetch?({:project_activation, id}, nil)

  def refresh_inventory?(_context, _root), do: false

  @impl true
  @spec enrich([Item.t()]) :: [Item.t()]
  def enrich(items), do: FileSource.enrich(items)

  @impl true
  @spec title() :: String.t()
  def title, do: "Attach project file to Agent"

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(context) do
    case async_fetch(context) do
      {:ok, items, _meta} -> items
      {:error, _reason} -> []
    end
  end

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{picker_ui: %{context: %{file: candidate, origin: origin}}} = context) do
    with {:ok, snapshot} <- capture(candidate) do
      targets = destination_items(origin, context, snapshot)

      case targets do
        [] ->
          {:error, "Open a local Agent composer before attaching a snapshot."}

        [_ | _] ->
          {:ok, Enum.map(targets, &put_file(&1, candidate)),
           %{project_activation_id: candidate.activation_id}}
      end
    end
  end

  def async_fetch(%Context{picker_ui: %{context: %{origin: origin}}} = context) do
    with {:ok, items, meta} <- FileSource.async_fetch(context) do
      {:ok, Enum.map(items, &put_origin(&1, origin)), meta}
    end
  end

  def async_fetch(context) do
    with {:ok, items, _meta} <- FileSource.async_fetch(context), do: {:ok, items, %{}}
  end

  @spec destination_items(origin(), Context.t(), DraftAttachment.text_snapshot()) :: [Item.t()]
  defp destination_items(nil, context, snapshot) do
    context
    |> Context.with_picker_context(%{source: snapshot})
    |> SelectionAttachmentTargetSource.candidates()
  end

  defp destination_items(origin, _context, snapshot) do
    [
      %Item{
        id: origin,
        label: "This Agent draft",
        description: "File snapshot",
        meta: %{source: snapshot}
      }
    ]
  end

  @spec put_origin(Item.t(), origin()) :: Item.t()
  defp put_origin(%Item{meta: meta} = item, origin),
    do: %{item | meta: Map.put(meta, :origin, origin)}

  @impl true
  @spec selection_disposition(Item.t(), Context.t()) :: Source.selection_disposition()
  def selection_disposition(%Item{id: %ProjectFileCandidate{} = candidate}, _context),
    do: current_file(candidate)

  def selection_disposition(%Item{meta: %{file: candidate}}, _context),
    do: current_file(candidate)

  def selection_disposition(_item, _context), do: {:reject, "File snapshot is unavailable."}

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(%Item{id: %ProjectFileCandidate{} = candidate, meta: %{origin: origin}}, state),
    do: PickerUI.open(state, __MODULE__, %{file: candidate, origin: origin})

  def on_select(%Item{} = item, state), do: SelectionAttachmentTargetSource.on_select(item, state)

  @spec capture(ProjectFileCandidate.t()) ::
          {:ok, DraftAttachment.text_snapshot()} | {:error, String.t()}
  defp capture(candidate) do
    with :accept <- current_file(candidate),
         {:ok, path} <- ProjectFileCandidate.resolve(candidate),
         {:ok, bytes} <- SecureFile.read(path, DraftAttachment.max_bytes()),
         :ok <- text_bytes(bytes) do
      {:ok, {:file, path, candidate.path, bytes}}
    else
      {:reject, message} -> {:error, message}
      {:error, {:file_too_large, _, _, _}} -> {:error, "Attach at most 32 KiB of text."}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "Could not read the selected project file."}
    end
  end

  @spec text_bytes(binary()) :: :ok | {:error, String.t()}
  defp text_bytes(""), do: {:error, "The selected file is empty."}

  defp text_bytes(bytes) do
    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, "The selected file is not UTF-8 text."}
  end

  @spec current_file(ProjectFileCandidate.t()) :: :accept | {:reject, String.t()}
  defp current_file(candidate) do
    if FileSource.current_candidate?(candidate),
      do: :accept,
      else: {:reject, "Project changed. Reopen the file attachment picker."}
  end

  @spec put_file(Item.t(), ProjectFileCandidate.t()) :: Item.t()
  defp put_file(%Item{description: description, meta: meta} = item, candidate),
    do: %{
      item
      | description: "#{description} · #{candidate.path}",
        meta: Map.put(meta, :file, candidate)
    }
end
