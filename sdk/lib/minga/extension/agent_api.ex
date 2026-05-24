defmodule Minga.Extension.AgentAPI do
  @moduledoc """
  Read-only facade for querying agent session state from extensions.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type session_summary :: %{
          id: String.t(),
          pid: pid(),
          status: :idle | :plan | :thinking | :tool_executing | :error,
          label: String.t(),
          model: String.t(),
          active_tool: String.t() | nil,
          created_at: DateTime.t()
        }

  @type session_info :: %{
          id: String.t(),
          pid: pid(),
          status: :idle | :plan | :thinking | :tool_executing | :error,
          label: String.t(),
          model: String.t(),
          active_tool: String.t() | nil,
          created_at: DateTime.t(),
          cost: float(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          turn_count: non_neg_integer(),
          files_touched: [String.t()]
        }

  @spec list_sessions() :: [session_summary()]
  def list_sessions, do: raise("minga_sdk is compile-time only")

  @spec session_info(pid()) :: {:ok, session_info()} | {:error, :not_found}
  def session_info(_pid), do: raise("minga_sdk is compile-time only")

  @spec subscribe() :: :ok
  def subscribe, do: raise("minga_sdk is compile-time only")

  @spec subscribe_edits() :: :ok
  def subscribe_edits, do: raise("minga_sdk is compile-time only")
end
