defmodule MingaAgent.EventLog.WriterState do
  @moduledoc "Owned runtime state and transitions for `MingaAgent.EventLog.Writer`."

  @enforce_keys [:owner, :owner_ref, :path, :backend, :backend_opts]
  defstruct [:owner, :owner_ref, :path, :backend, :backend_opts, :db]

  @type t :: %__MODULE__{
          owner: pid(),
          owner_ref: reference(),
          path: String.t(),
          backend: module(),
          backend_opts: keyword(),
          db: term() | nil
        }

  @doc "Builds writer state before the database connection opens."
  @spec new(pid(), String.t(), module(), keyword()) :: t()
  def new(owner, path, backend, backend_opts)
      when is_pid(owner) and is_binary(path) and is_atom(backend) and is_list(backend_opts) do
    %__MODULE__{
      owner: owner,
      owner_ref: Process.monitor(owner),
      path: path,
      backend: backend,
      backend_opts: backend_opts
    }
  end

  @doc "Stores the connection exclusively owned by the writer."
  @spec opened(t(), term()) :: t()
  def opened(state, db), do: %{state | db: db}
end
