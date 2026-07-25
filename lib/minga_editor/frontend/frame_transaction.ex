defmodule MingaEditor.Frontend.FrameTransaction do
  @moduledoc """
  Validates the render-frame boundary before a command batch reaches a frontend.

  Semantic render commands must appear between matching `begin_frame` and `commit_frame` markers. Only a deliberately small set of setup and side-channel commands may be emitted outside a frame. The manager logs violations before it writes the batch so a producer regression is attributable without inspecting payload content.
  """

  alias Minga.Protocol.Opcodes

  @op_begin_frame Opcodes.begin_frame()
  @op_commit_frame Opcodes.commit_frame()
  @out_of_band_opcodes [
    Opcodes.set_title(),
    Opcodes.set_window_bg(),
    Opcodes.set_link_cursor(),
    Opcodes.protocol_error(),
    Opcodes.set_font(),
    Opcodes.set_font_fallback(),
    Opcodes.register_font(),
    Opcodes.gui_config_state(),
    Opcodes.clipboard_write()
  ]

  @retired_frame_body_opcodes [0x12, 0x13, 0x14, 0x1A, 0x1B, 0x1C]

  @type frame_seq :: non_neg_integer()
  @type state :: :outside | {:inside, frame_seq()}

  @type validation_error ::
          {:malformed_command}
          | {:begin_while_open, frame_seq()}
          | {:commit_without_begin, frame_seq()}
          | {:commit_seq_mismatch, expected :: frame_seq(), received :: frame_seq()}
          | {:unterminated_frame, frame_seq()}
          | {:out_of_transaction_command, opcode :: non_neg_integer()}
          | {:retired_render_command, opcode :: non_neg_integer()}

  @doc "Validates one ordered frontend command batch without inspecting payload data."
  @spec validate([binary()]) :: :ok | {:error, validation_error()}
  def validate(commands) when is_list(commands), do: validate(commands, :outside)

  @doc "Formats a validation error using only protocol metadata, never command payloads."
  @spec format_error(validation_error()) :: String.t()
  def format_error({:malformed_command}), do: "malformed empty command"

  def format_error({:begin_while_open, frame_seq}),
    do: "begin_frame while frame #{frame_seq} is open"

  def format_error({:commit_without_begin, frame_seq}),
    do: "commit_frame #{frame_seq} without begin_frame"

  def format_error({:commit_seq_mismatch, expected, received}),
    do: "commit_frame #{received} does not match begin_frame #{expected}"

  def format_error({:unterminated_frame, frame_seq}), do: "unterminated frame #{frame_seq}"

  def format_error({:out_of_transaction_command, opcode}),
    do: "opcode 0x#{Integer.to_string(opcode, 16) |> String.pad_leading(2, "0")} outside a frame"

  def format_error({:retired_render_command, opcode}),
    do:
      "retired render opcode 0x#{Integer.to_string(opcode, 16) |> String.pad_leading(2, "0")} inside a frame"

  @spec validate([binary()], state()) :: :ok | {:error, validation_error()}
  defp validate([], :outside), do: :ok
  defp validate([], {:inside, frame_seq}), do: {:error, {:unterminated_frame, frame_seq}}
  defp validate([<<>> | _commands], _state), do: {:error, :malformed_command}

  defp validate(
         [<<@op_begin_frame, frame_seq::32, _base_frame_seq::32, _generation::32>> | commands],
         :outside
       ),
       do: validate(commands, {:inside, frame_seq})

  defp validate(
         [<<@op_begin_frame, _frame_seq::32, _base_frame_seq::32, _generation::32>> | _commands],
         {:inside, open_frame_seq}
       ),
       do: {:error, {:begin_while_open, open_frame_seq}}

  defp validate([<<@op_commit_frame, frame_seq::32, _input_seq::32>> | _commands], :outside),
    do: {:error, {:commit_without_begin, frame_seq}}

  defp validate(
         [<<@op_commit_frame, frame_seq::32, _input_seq::32>> | commands],
         {:inside, frame_seq}
       ),
       do: validate(commands, :outside)

  defp validate(
         [<<@op_commit_frame, received_frame_seq::32, _input_seq::32>> | _commands],
         {:inside, expected_frame_seq}
       ),
       do: {:error, {:commit_seq_mismatch, expected_frame_seq, received_frame_seq}}

  defp validate([<<opcode, _::binary>> | commands], :outside) when opcode in @out_of_band_opcodes,
    do: validate(commands, :outside)

  defp validate([<<opcode, _::binary>> | _commands], :outside),
    do: {:error, {:out_of_transaction_command, opcode}}

  defp validate([<<opcode, _::binary>> | _commands], {:inside, _frame_seq})
       when opcode in @retired_frame_body_opcodes,
       do: {:error, {:retired_render_command, opcode}}

  defp validate([_command | commands], {:inside, frame_seq}),
    do: validate(commands, {:inside, frame_seq})
end
