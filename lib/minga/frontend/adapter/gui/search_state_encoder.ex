defmodule Minga.Frontend.Adapter.GUI.SearchStateEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.SearchState

  @op_gui_search_state Opcodes.gui_search_state()

  @search_flag_replace_mode 0x01
  @search_flag_case_sensitive 0x02
  @search_flag_whole_word 0x04
  @search_flag_regex 0x08

  @max_u16 65_535

  @spec encode(SearchState.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%SearchState{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_search_state_fp do
      cmd = encode_search_state_binary(model)
      {cmd, %{caches | last_search_state_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_search_state_binary(SearchState.t()) :: binary()
  defp encode_search_state_binary(%SearchState{} = model) do
    active_byte = if model.active, do: 1, else: 0
    count = min(model.match_count, @max_u16)
    idx = min(model.current_index, @max_u16)

    flag_byte =
      if(model.replace_mode, do: @search_flag_replace_mode, else: 0) |||
        if(model.case_sensitive, do: @search_flag_case_sensitive, else: 0) |||
        if(model.whole_word, do: @search_flag_whole_word, else: 0) |||
        if(model.regex, do: @search_flag_regex, else: 0)

    payload = <<active_byte::8, count::16, idx::16, flag_byte::8>>

    <<@op_gui_search_state, byte_size(payload)::16, payload::binary>>
  end
end
