defmodule Minga.SystemObserver.RestartRecord do
  @moduledoc """
  Records a supervisor restart event detected by the always-on monitoring tier.

  Stored in `SystemObserver`'s state and accessible via `restart_history/0`.
  Also broadcast as a `Minga.Events.SupervisorRestartedEvent` for push
  notification to UI components.
  """

  @enforce_keys [:name, :pid, :reason, :timestamp, :wall_time]
  defstruct [:name, :pid, :reason, :timestamp, :wall_time]

  @type t :: %__MODULE__{
          name: atom(),
          pid: pid(),
          reason: term(),
          timestamp: integer(),
          wall_time: DateTime.t()
        }
end
