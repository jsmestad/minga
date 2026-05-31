defmodule MingaAgent.OAuth.ManualCLITest do
  use ExUnit.Case, async: true

  alias MingaAgent.OAuth.ManualCLI

  test "prints the authorize URL, reads pasted input, and completes the flow" do
    parent = self()

    begin_fun = fn -> {:ok, "https://auth.example/authorize", "flow-ref"} end

    complete_fun = fn ref, pasted ->
      send(parent, {:complete, ref, pasted})
      {:ok, :openai}
    end

    input_fun = fn prompt ->
      send(parent, {:prompt, prompt})
      "pasted_code\n"
    end

    output_fun = fn message -> send(parent, {:output, message}) end

    assert :ok =
             ManualCLI.run(
               begin_fun: begin_fun,
               complete_fun: complete_fun,
               input_fun: input_fun,
               output_fun: output_fun
             )

    assert_receive {:output, "Open this URL in your browser to sign in:"}
    assert_receive {:output, "https://auth.example/authorize"}
    assert_receive {:output, "Flow ref: flow-ref"}
    assert_receive {:prompt, "Paste redirect value: "}
    assert_receive {:complete, "flow-ref", "pasted_code"}
  end

  test "returns a clear error when stdin closes" do
    assert {:error, message} =
             ManualCLI.run(
               begin_fun: fn -> {:ok, "url", "ref"} end,
               input_fun: fn _prompt -> nil end,
               output_fun: fn _message -> :ok end
             )

    assert message =~ "No redirect value was provided"
  end
end
