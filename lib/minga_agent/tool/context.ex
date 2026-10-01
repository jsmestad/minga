defmodule MingaAgent.Tool.Context do
  @moduledoc """
  Per-session runtime context for building executable agent tools.

  This is a narrow capability object. It gives tool builders the project root, routed workspace access, command working directory data, and correlation ids without exposing raw session state.
  """

  alias MingaAgent.ToolRouter
  alias MingaAgent.ToolRouter.Context, as: RouterContext

  @type capture_key :: {:delivery, String.t(), String.t()}
  @type image_tool_result_delivery :: MingaAgent.ModelSelection.image_tool_result_delivery()

  @typedoc "Opaque-ish runtime context passed to source-owned tool builders."
  @type t :: %__MODULE__{
          project_root: String.t(),
          router_context: RouterContext.t(),
          artifact_store: GenServer.server() | nil,
          capture_key: capture_key() | nil,
          image_tool_result_delivery: image_tool_result_delivery(),
          session_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:project_root, :router_context]
  defstruct [
    :project_root,
    :router_context,
    :artifact_store,
    :capture_key,
    :image_tool_result_delivery,
    :session_id,
    metadata: %{}
  ]

  @doc "Builds a tool context from runtime values."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    project_root = Keyword.fetch!(attrs, :project_root)

    router_context =
      Keyword.get_lazy(attrs, :router_context, fn ->
        ToolRouter.context(
          Keyword.get(attrs, :project_view),
          Keyword.get(attrs, :fork_store),
          Keyword.get(attrs, :changeset)
        )
      end)

    %__MODULE__{
      project_root: project_root,
      router_context: router_context,
      artifact_store: Keyword.get(attrs, :artifact_store),
      capture_key: Keyword.get(attrs, :capture_key),
      image_tool_result_delivery:
        Keyword.get(
          attrs,
          :image_tool_result_delivery,
          {:unsupported, :tool_result_transport}
        ),
      session_id: Keyword.get(attrs, :session_id),
      metadata: Keyword.get(attrs, :metadata, %{})
    }
  end

  @doc "Scopes a record-owned artifact capability to one durably admitted tool call."
  @spec for_tool_call(t(), GenServer.server(), String.t(), String.t()) :: t()
  def for_tool_call(%__MODULE__{} = context, artifact_store, checkpoint_id, tool_call_id)
      when (is_pid(artifact_store) or is_atom(artifact_store) or is_tuple(artifact_store)) and
             is_binary(checkpoint_id) and is_binary(tool_call_id) do
    %{
      context
      | artifact_store: artifact_store,
        capture_key: {:delivery, checkpoint_id, tool_call_id}
    }
  end

  @doc "Returns opts accepted by `MingaAgent.Tools.all/1`."
  @spec tools_opts(t()) :: keyword()
  def tools_opts(%__MODULE__{} = context) do
    [
      project_root: context.project_root,
      project_view: context.router_context.project_view,
      fork_store: context.router_context.fork_store,
      changeset: context.router_context.changeset,
      parent_session: Map.get(context.metadata, :parent_session),
      shell_output_callback: Map.get(context.metadata, :shell_output_callback),
      artifact_store: context.artifact_store,
      capture_key: context.capture_key,
      image_tool_result_delivery: context.image_tool_result_delivery
    ]
  end

  @doc "Reads a file through the session router."
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{} = context, path) do
    ToolRouter.read_file(context.router_context, path)
  end

  @doc "Captures a routed file with exact retained bytes and source revision."
  @spec capture_file(t(), String.t(), keyword()) ::
          {:ok, MingaAgent.Tool.Output.t()}
          | {:error, MingaAgent.Tool.Output.t() | term()}
  def capture_file(%__MODULE__{} = context, path, opts \\ []) when is_binary(path) do
    capture_opts =
      Keyword.put(opts, :image_tool_result_delivery, context.image_tool_result_delivery)

    ToolRouter.capture_file(
      context.router_context,
      path,
      context.artifact_store,
      context.capture_key,
      capture_opts
    )
  end

  @doc "Fetches exact retained bytes from this record's artifact owner without replaying a tool."
  @spec fetch_output(t(), MingaAgent.Tool.Output.Reference.t(), MingaAgent.Tool.Output.Range.t()) ::
          {:ok, term()} | {:error, term()}
  def fetch_output(%__MODULE__{artifact_store: nil}, _reference, _range),
    do: {:error, :retention_unavailable}

  def fetch_output(%__MODULE__{} = context, reference, range) do
    MingaAgent.ArtifactStore.fetch(context.artifact_store, reference, range)
  end

  @doc "Writes a file through the session router."
  @spec write_file(t(), String.t(), binary()) :: :ok | :passthrough | {:error, term()}
  def write_file(%__MODULE__{} = context, path, content) do
    ToolRouter.write_file(context.router_context, path, content)
  end

  @doc "Edits a file through the session router."
  @spec edit_file(t(), String.t(), String.t(), String.t()) ::
          :ok | :passthrough | {:error, term()}
  def edit_file(%__MODULE__{} = context, path, old_text, new_text) do
    ToolRouter.edit_file(context.router_context, path, old_text, new_text)
  end

  @doc "Deletes a file through the session router."
  @spec delete_file(t(), String.t()) :: :ok | :passthrough | {:error, term()}
  def delete_file(%__MODULE__{} = context, path) do
    ToolRouter.delete_file(context.router_context, path)
  end

  @doc "Returns the command working directory for this context."
  @spec working_dir(t()) :: String.t() | nil
  def working_dir(%__MODULE__{} = context), do: ToolRouter.working_dir(context.router_context)

  @doc "Returns command environment entries for this context."
  @spec command_env(t()) :: [{String.t(), String.t()}]
  def command_env(%__MODULE__{} = context), do: ToolRouter.command_env(context.router_context)
end
