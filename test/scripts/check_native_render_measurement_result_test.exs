defmodule Minga.CheckNativeRenderMeasurementResultTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check_native_render_measurement_result", __DIR__)

  test "accepts success without an output file" do
    assert {_output, 0} = classify(0, missing_output_path())
  end

  test "defers only a budget breach that produced a measurement" do
    output = measurement_path()
    File.write!(output, "{}")
    on_exit(fn -> File.rm(output) end)

    assert {_output, 0} = classify(1, output)
    assert {_output, 2} = classify(2, output)
    assert {_output, 139} = classify(139, output)
  end

  test "rejects a budget exit without a measurement" do
    assert {_output, 1} = classify(1, missing_output_path())
  end

  defp classify(status, output) do
    System.cmd("bash", [@script, Integer.to_string(status), output], stderr_to_stdout: true)
  end

  defp measurement_path do
    Path.join(
      System.tmp_dir!(),
      "minga-native-measurement-#{System.unique_integer([:positive])}.json"
    )
  end

  defp missing_output_path do
    Path.join(
      System.tmp_dir!(),
      "minga-native-missing-#{System.unique_integer([:positive])}.json"
    )
  end
end
