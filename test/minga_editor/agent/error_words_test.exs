defmodule MingaEditor.Agent.ErrorWordsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.ErrorWords

  doctest ErrorWords

  for {reason, words} <- [
        {"No active agent session", "No active agent session"},
        {:provider_not_ready, "provider not ready"},
        {{:conversation_persistence_failed, :invalid_continuation_boundaries},
         "the conversation could not be saved (invalid continuation boundaries)"},
        {{:conversation_persistence_failed, {:io, :enospc}},
         "the conversation could not be saved ({:io, :enospc})"},
        {nil, "nil"},
        {true, "true"},
        {{:unexpected, 1}, "{:unexpected, 1}"},
        {%{code: 3}, "%{code: 3}"}
      ] do
    test "describes #{inspect(reason)} as plain words" do
      assert ErrorWords.describe(unquote(Macro.escape(reason))) == unquote(words)
    end
  end
end
