defmodule MingaAgent.Session.ConnectionTarget do
  @moduledoc """
  Identifies the exact live conversation and model/profile that offered setup.

  The epoch is process-local and never persisted or transported to a frontend.
  Returning to a previous selection does not revive an earlier target.
  """

  alias MingaAgent.ModelSelection

  @enforce_keys [:session, :session_id, :epoch]
  defstruct [:session, :session_id, :selection_id, :credential_id, :epoch]

  @type t :: %__MODULE__{
          session: pid(),
          session_id: String.t(),
          selection_id: String.t() | nil,
          credential_id: String.t() | nil,
          epoch: reference()
        }

  @doc "Captures the current Session-owned identity without acquiring credentials."
  @spec new(pid(), String.t(), ModelSelection.t() | nil, reference()) :: t()
  def new(session, session_id, selection, epoch)
      when is_pid(session) and is_binary(session_id) and is_reference(epoch) do
    %__MODULE__{
      session: session,
      session_id: session_id,
      selection_id: selection_id(selection),
      credential_id: credential_id(selection),
      epoch: epoch
    }
  end

  @spec selection_id(ModelSelection.t() | nil) :: String.t() | nil
  defp selection_id(nil), do: nil
  defp selection_id(selection), do: ModelSelection.id(selection)

  @spec credential_id(ModelSelection.t() | nil) :: String.t() | nil
  defp credential_id(nil), do: nil
  defp credential_id(selection), do: ModelSelection.credential_id(selection.credential)
end
