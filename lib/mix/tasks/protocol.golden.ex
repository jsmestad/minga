defmodule Mix.Tasks.Protocol.Golden do
  @moduledoc """
  Writes the cross-language protocol golden manifest.

  Encodes fixture editor state with the production GUI adapter encoders and
  records, per fixture, the payload bytes and the field values the generated
  decoders must produce. The manifest is consumed by the Go cross-language
  golden test (`go/tui/internal/protocol/golden_cross_lang_test.go`), which
  decodes each payload with the schema-generated Go decoder and compares it
  field-by-field. Together they make payload drift between the Elixir encoders
  and the generated decoders a CI failure.

  Must run under `MIX_ENV=test` because the fixtures live in the test support
  tree. Run with `--check` to verify the committed manifest is current instead
  of rewriting it.

      MIX_ENV=test mix protocol.golden
      MIX_ENV=test mix protocol.golden --check
  """

  use Mix.Task

  @shortdoc "Writes the cross-language protocol golden manifest"

  @manifest_path "go/tui/internal/protocol/testdata/golden/manifest.json"

  @fixtures_module Minga.Test.ProtocolGolden

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.config")
    Mix.Task.run("loadpaths")
    ensure_fixtures_available!()

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    content = manifest_json()

    case Keyword.get(opts, :check, false) do
      true -> check_manifest!(content)
      false -> write_manifest!(content)
    end
  end

  # The fixtures live in the test support tree, so this task only works under
  # MIX_ENV=test. Fail with a clear message instead of an opaque UndefinedFunctionError.
  @spec ensure_fixtures_available!() :: :ok
  defp ensure_fixtures_available! do
    case Code.ensure_loaded(@fixtures_module) do
      {:module, _} ->
        :ok

      {:error, _} ->
        Mix.raise(
          "#{inspect(@fixtures_module)} is not loaded. Run this task under MIX_ENV=test (e.g. `MIX_ENV=test mix protocol.golden`)."
        )
    end
  end

  @spec manifest_json() :: String.t()
  defp manifest_json do
    # apply/3 keeps the test-support module out of dev-env compile-time
    # resolution; ensure_loaded! above guards the runtime call.
    @fixtures_module
    |> apply(:manifest, [])
    |> JSON.encode!()
    |> Kernel.<>("\n")
  end

  @spec write_manifest!(String.t()) :: :ok
  defp write_manifest!(content) do
    @manifest_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(@manifest_path, content)
    Mix.shell().info("Wrote #{@manifest_path}")
  end

  @spec check_manifest!(String.t()) :: :ok
  defp check_manifest!(expected) do
    case File.read(@manifest_path) do
      {:ok, ^expected} ->
        :ok

      _ ->
        Mix.raise(
          "Golden manifest is out of date. Run `MIX_ENV=test mix protocol.golden` to regenerate.\n  - #{@manifest_path}"
        )
    end
  end
end
