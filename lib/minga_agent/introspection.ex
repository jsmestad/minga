defmodule MingaAgent.Introspection do
  @moduledoc """
  Runtime self-description for external clients.

  Produces structured capability manifests, tool descriptions, and
  session descriptions. All functions are pure data transforms over
  the current registry and session state. No side effects beyond
  ETS reads and one GenServer call.

  External clients use this to discover what the runtime can do
  before making requests. The API gateway exposes these as JSON-RPC
  methods.
  """

  alias MingaAgent.Tool.{Registry, Spec}
  alias MingaAgent.SessionManager

  @typedoc "Runtime capabilities manifest."
  @type capabilities_manifest :: %{
          version: String.t(),
          tool_count: non_neg_integer(),
          session_count: non_neg_integer(),
          tool_categories: [Spec.category()],
          features: [atom()]
        }

  @typedoc "Structured tool description for external clients."
  @type tool_description :: %{
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          category: Spec.category(),
          approval_level: Spec.approval_level()
        }

  @typedoc "Structured session description for external clients."
  @type session_description :: %{
          session_id: String.t(),
          model_name: String.t(),
          status: atom(),
          created_at: String.t()
        }

  @doc "Returns a capabilities manifest describing the runtime."
  @spec capabilities() :: capabilities_manifest()
  def capabilities do
    tools = Registry.all()
    sessions = SessionManager.list_sessions()
    categories = tools |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()

    %{
      version: app_version(),
      tool_count: length(tools),
      session_count: length(sessions),
      tool_categories: categories,
      features: enabled_features()
    }
  end

  @doc "Returns structured descriptions of all registered tools."
  @spec describe_tools() :: [tool_description()]
  def describe_tools do
    Registry.all()
    |> Enum.map(fn %Spec{} = s ->
      %{
        name: s.name,
        description: s.description,
        parameter_schema: s.parameter_schema,
        category: s.category,
        approval_level: s.approval_level
      }
    end)
  end

  @doc "Returns structured descriptions of all active sessions."
  @spec describe_sessions() :: [session_description()]
  def describe_sessions do
    SessionManager.list_sessions()
    |> Enum.map(fn {id, _pid, metadata} ->
      %{
        session_id: id,
        model_name: metadata.model_name,
        status: metadata.status,
        created_at: DateTime.to_iso8601(metadata.created_at)
      }
    end)
  end

  @spec app_version() :: String.t()
  defp app_version do
    case Application.spec(:minga, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  @spec enabled_features() :: [atom()]
  defp enabled_features do
    [:tools, :sessions, :events, :changesets, :buffer_fork]
  end
end
