defmodule MingaEditor.MacroRecorder do
  @moduledoc """
  Records and replays named keystroke macros.

  The `phase` carries exactly one active lifecycle, while replay can preserve a post-replay recording phase that is restored after the outermost replay returns normally.
  """

  defstruct phase: :idle,
            registers: %{},
            last_register: nil

  @type key :: {non_neg_integer(), non_neg_integer()}

  @type post_phase :: :idle | {:recording, String.t(), [key()]}
  @type phase ::
          :idle | {:recording, String.t(), [key()]} | {:replaying, pos_integer(), post_phase()}

  @type t :: %__MODULE__{
          phase: phase(),
          registers: %{String.t() => [key()]},
          last_register: String.t() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec start_recording(t(), String.t()) :: t()
  def start_recording(%__MODULE__{phase: {:replaying, depth, _post}} = rec, register)
      when is_binary(register) do
    %{rec | phase: {:replaying, depth, {:recording, register, []}}, last_register: register}
  end

  def start_recording(%__MODULE__{} = rec, register) when is_binary(register) do
    %{rec | phase: {:recording, register, []}, last_register: register}
  end

  @spec record_key(t(), key()) :: t()
  def record_key(%__MODULE__{phase: {:recording, reg, keys}} = rec, key) do
    %{rec | phase: {:recording, reg, [key | keys]}}
  end

  def record_key(%__MODULE__{} = rec, _key), do: rec

  @spec stop_recording(t()) :: t()
  def stop_recording(%__MODULE__{phase: {:recording, reg, keys}} = rec) do
    %{rec | phase: :idle, registers: Map.put(rec.registers, reg, Enum.reverse(keys))}
  end

  def stop_recording(%__MODULE__{phase: {:replaying, depth, {:recording, reg, keys}}} = rec) do
    %{
      rec
      | phase: {:replaying, depth, :idle},
        registers: Map.put(rec.registers, reg, Enum.reverse(keys))
    }
  end

  def stop_recording(%__MODULE__{} = rec), do: rec

  @spec put_macro(t(), String.t(), [key()]) :: t()
  def put_macro(%__MODULE__{} = rec, register, keys) when is_binary(register) and is_list(keys) do
    %{rec | registers: Map.put(rec.registers, register, keys)}
  end

  @spec get_macro(t(), String.t()) :: [key()] | nil
  def get_macro(%__MODULE__{registers: regs}, register) do
    Map.get(regs, register)
  end

  @spec recording?(t()) :: {true, String.t()} | false
  def recording?(%__MODULE__{phase: {:recording, reg, _keys}}), do: {true, reg}

  def recording?(%__MODULE__{phase: {:replaying, _depth, {:recording, reg, _keys}}}),
    do: {true, reg}

  def recording?(%__MODULE__{}), do: false

  @spec replaying?(t()) :: boolean()
  def replaying?(%__MODULE__{phase: {:replaying, _depth, _post}}), do: true
  def replaying?(%__MODULE__{}), do: false

  @spec start_replay(t()) :: t()
  def start_replay(%__MODULE__{phase: {:replaying, depth, post}} = rec) do
    %{rec | phase: {:replaying, depth + 1, post}}
  end

  def start_replay(%__MODULE__{phase: phase} = rec) do
    %{rec | phase: {:replaying, 1, phase}}
  end

  @spec stop_replay(t()) :: t()
  def stop_replay(%__MODULE__{phase: {:replaying, depth, post}} = rec) when depth > 1 do
    %{rec | phase: {:replaying, depth - 1, post}}
  end

  def stop_replay(%__MODULE__{phase: {:replaying, 1, post}} = rec) do
    %{rec | phase: post}
  end

  def stop_replay(%__MODULE__{} = rec), do: rec

  @spec select_replay_register(t(), String.t()) :: t()
  def select_replay_register(%__MODULE__{} = rec, register) when is_binary(register) do
    %{rec | last_register: register}
  end

  @spec last_register(t()) :: String.t() | nil
  def last_register(%__MODULE__{last_register: register}), do: register
end
