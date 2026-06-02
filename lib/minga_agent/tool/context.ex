defmodule MingaAgent.Tool.Context do
  @moduledoc """
  Per-session runtime context for building executable agent tools.

  This is a narrow capability object. It gives tool builders the project root, routed workspace access, command working directory data, and correlation ids without exposing raw session state.
  """

  alias MingaAgent.ToolRouter
  alias MingaAgent.ToolRouter.Context, as: RouterContext

  @typedoc "Opaque-ish runtime context passed to source-owned tool builders."
  @type t :: %__MODULE__{
          project_root: String.t(),
          router_context: RouterContext.t(),
          session_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:project_root, :router_context]
  defstruct [:project_root, :router_context, :session_id, metadata: %{}]

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
      session_id: Keyword.get(attrs, :session_id),
      metadata: Keyword.get(attrs, :metadata, %{})
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
      shell_output_callback: Map.get(context.metadata, :shell_output_callback)
    ]
  end

  @doc "Reads a file through the session router."
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{} = context, path) do
    ToolRouter.read_file(context.router_context, path)
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
