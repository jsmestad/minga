defmodule MingaEditor.Renderer.ObservedBuffers do
  @moduledoc """
  Renderer-local buffer monitor and consumed-version owner.
  Versions are retained only for currently monitored buffers. Exact `:DOWN`
  matching removes both the monitor reference and the recorded version, while
  stale `:DOWN` messages are ignored.
  """

  @type t :: %__MODULE__{
          monitors: %{optional(pid()) => reference()},
          versions: %{optional(pid()) => non_neg_integer()}
        }

  defstruct monitors: %{}, versions: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec reconcile(t(), MapSet.t(pid())) :: t()
  def reconcile(%__MODULE__{} = observed, %MapSet{} = buffers) do
    Enum.each(observed.monitors, fn {buffer, ref} ->
      if not MapSet.member?(buffers, buffer), do: Process.demonitor(ref, [:flush])
    end)

    monitors =
      Map.new(buffers, fn buffer ->
        {buffer, Map.get_lazy(observed.monitors, buffer, fn -> Process.monitor(buffer) end)}
      end)

    %__MODULE__{
      monitors: monitors,
      versions: Map.take(observed.versions, MapSet.to_list(buffers))
    }
  end

  @spec record_version(t(), pid(), non_neg_integer()) :: t()
  def record_version(%__MODULE__{} = observed, buffer, version)
      when is_pid(buffer) and is_integer(version) and version >= 0 do
    if Map.has_key?(observed.monitors, buffer) do
      %{observed | versions: Map.put(observed.versions, buffer, version)}
    else
      observed
    end
  end

  @spec drop_down(t(), reference(), pid()) :: {t(), boolean()}
  def drop_down(%__MODULE__{} = observed, ref, buffer)
      when is_reference(ref) and is_pid(buffer) do
    case Map.get(observed.monitors, buffer) do
      ^ref ->
        {%{
           observed
           | monitors: Map.delete(observed.monitors, buffer),
             versions: Map.delete(observed.versions, buffer)
         }, true}

      _other ->
        {observed, false}
    end
  end

  @spec recorded_version(t(), pid()) :: non_neg_integer() | nil
  def recorded_version(%__MODULE__{} = observed, buffer) when is_pid(buffer),
    do: Map.get(observed.versions, buffer)

  @spec monitored_versions(t(), %{optional(pid()) => non_neg_integer()}) :: %{
          optional(pid()) => non_neg_integer()
        }
  def monitored_versions(%__MODULE__{} = observed, versions) when is_map(versions),
    do: Map.take(versions, Map.keys(observed.monitors))
end
