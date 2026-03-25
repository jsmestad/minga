defmodule Minga.Editor.MacroRecorder do
  @moduledoc """
  Records and replays named keystroke macros.

  A pure functional module — no GenServer. The struct is embedded in
  `Minga.Editor.State` and threaded through the editor's key dispatch.

  Macros are stored in named registers (`a`–`z`), separate from text
  registers. Each register holds a list of key tuples that can be
  replayed through the editor's `handle_key` pipeline.
  """

  defstruct recording: nil,
            registers: %{},
            replaying: false,
            last_register: nil

  @typedoc "A key event: `{codepoint, modifiers}`."
  @type key :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Recording state: `{register_name, accumulated_keys}` or nil."
  @type recording :: {String.t(), [key()]} | nil

  @type t :: %__MODULE__{
          recording: recording(),
          registers: %{String.t() => [key()]},
          replaying: boolean(),
          last_register: String.t() | nil
        }

  @doc "Returns a fresh macro recorder with no recorded macros."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Begins recording into the named register."
  @spec start_recording(t(), String.t()) :: t()
  def start_recording(%__MODULE__{} = rec, register) when is_binary(register) do
    %{rec | recording: {register, []}}
  end

  @doc "Appends a key to the active recording. No-op if not recording."
  @spec record_key(t(), key()) :: t()
  def record_key(%__MODULE__{recording: {reg, keys}} = rec, key) do
    %{rec | recording: {reg, [key | keys]}}
  end

  def record_key(%__MODULE__{} = rec, _key), do: rec

  @doc "Finalizes the current recording, storing the key sequence in the register."
  @spec stop_recording(t()) :: t()
  def stop_recording(%__MODULE__{recording: {reg, keys}} = rec) do
    %{rec | recording: nil, registers: Map.put(rec.registers, reg, Enum.reverse(keys))}
  end

  def stop_recording(%__MODULE__{} = rec), do: rec

  @doc "Returns the stored key sequence for a register, or nil."
  @spec get_macro(t(), String.t()) :: [key()] | nil
  def get_macro(%__MODULE__{registers: regs}, register) do
    Map.get(regs, register)
  end

  @doc "Returns `{true, register_name}` if recording, or `false`."
  @spec recording?(t()) :: {true, String.t()} | false
  def recording?(%__MODULE__{recording: {reg, _keys}}), do: {true, reg}
  def recording?(%__MODULE__{}), do: false

  @doc "Returns true if currently replaying a macro."
  @spec replaying?(t()) :: boolean()
  def replaying?(%__MODULE__{replaying: r}), do: r

  @doc "Sets the replaying flag."
  @spec start_replay(t()) :: t()
  def start_replay(%__MODULE__{} = rec), do: %{rec | replaying: true}

  @doc "Clears the replaying flag."
  @spec stop_replay(t()) :: t()
  def stop_replay(%__MODULE__{} = rec), do: %{rec | replaying: false}
end
