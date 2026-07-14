defmodule MingaEditor.Shell.Traditional.Observatory do
  @moduledoc """
  Pure lifecycle owner for the Traditional shell's BEAM Observatory.

  Refresh timers are correlated by semantic tokens. Expiring a scheduled
  refresh moves it to an in-flight state, and only the matching result can
  install data and arm the next refresh. Closing clears every surface value,
  so delayed ticks and results cannot restore a hidden observatory.
  """

  alias MingaEditor.Observatory.Data
  alias MingaEditor.Observatory.Inspection

  @type phase :: :idle | :scheduled | :collecting
  @type timer :: {reference(), reference()}
  @type t :: %__MODULE__{
          visible: boolean(),
          data: Data.t() | nil,
          timer: reference() | nil,
          token: reference() | nil,
          phase: phase(),
          inspection: Inspection.t() | nil
        }

  defstruct visible: false,
            data: nil,
            timer: nil,
            token: nil,
            phase: :idle,
            inspection: nil

  @doc "Returns whether the Observatory surface is visible."
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{visible: visible}), do: visible

  @doc "Opens the surface and installs its first scheduled refresh."
  @spec open(t(), timer() | nil) :: t()
  def open(%__MODULE__{} = observatory, {timer, token})
      when is_reference(timer) and is_reference(token) do
    %{
      observatory
      | visible: true,
        timer: timer,
        token: token,
        phase: :scheduled,
        inspection: nil
    }
  end

  def open(%__MODULE__{} = observatory, nil) do
    %{observatory | visible: true, timer: nil, token: nil, phase: :idle, inspection: nil}
  end

  @doc "Closes the surface and invalidates scheduled or in-flight refreshes."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = observatory) do
    %__MODULE__{
      observatory
      | visible: false,
        data: nil,
        timer: nil,
        token: nil,
        phase: :idle,
        inspection: nil
    }
  end

  @doc "Returns the latest collected Observatory data."
  @spec data(t()) :: Data.t() | nil
  def data(%__MODULE__{data: data}), do: data

  @doc "Returns the active process inspection, when present."
  @spec inspection(t()) :: Inspection.t() | nil
  def inspection(%__MODULE__{inspection: inspection}), do: inspection

  @doc "Returns the timer handle that an effectful workflow should cancel."
  @spec timer(t()) :: reference() | nil
  def timer(%__MODULE__{timer: timer}), do: timer

  @doc "Expires a matching scheduled refresh and marks its collection in flight."
  @spec expire(t(), reference()) :: {:collect | :stale, t()}
  def expire(
        %__MODULE__{visible: true, phase: :scheduled, token: token} = observatory,
        token
      ) do
    {:collect, %{observatory | timer: nil, phase: :collecting}}
  end

  def expire(%__MODULE__{} = observatory, _token), do: {:stale, observatory}

  @doc "Returns whether a collection token is currently in flight."
  @spec collecting?(t(), reference()) :: boolean()
  def collecting?(%__MODULE__{visible: true, phase: :collecting, token: token}, token), do: true
  def collecting?(%__MODULE__{}, _token), do: false

  @doc "Completes a matching collection and schedules the next refresh."
  @spec complete(t(), reference(), Data.t(), timer()) :: {:accepted | :stale, t()}
  def complete(
        %__MODULE__{visible: true, phase: :collecting, token: token} = observatory,
        token,
        %Data{} = data,
        {timer, next_token}
      )
      when is_reference(timer) and is_reference(next_token) do
    {:accepted,
     %{
       observatory
       | data: data,
         timer: timer,
         token: next_token,
         phase: :scheduled
     }}
  end

  def complete(%__MODULE__{} = observatory, _token, %Data{}, {_timer, _next_token}),
    do: {:stale, observatory}

  @doc "Installs data without changing refresh correlation."
  @spec replace_data(t(), Data.t() | nil) :: t()
  def replace_data(%__MODULE__{} = observatory, data), do: %{observatory | data: data}

  @doc "Shows or dismisses the process inspection float."
  @spec inspect(t(), Inspection.t() | nil) :: t()
  def inspect(%__MODULE__{} = observatory, inspection),
    do: %{observatory | inspection: inspection}
end
