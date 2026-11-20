defmodule Minga.Test.ElixirSubprocess do
  @moduledoc false

  @doc "Evaluates Elixir in the current toolchain without invoking a HOME-dependent shim."
  @spec eval(String.t(), [String.t()], System.cmd_opts()) :: {Collectable.t(), non_neg_integer()}
  def eval(code, args, opts) do
    erl = Path.join(to_string(:code.root_dir()), "bin/erl")
    elixir_lib = to_string(:code.lib_dir(:elixir))
    minga_ebin = Path.dirname(to_string(:code.which(Minga)))

    System.cmd(
      erl,
      [
        "+S",
        "1:1",
        "-noshell",
        "-elixir_root",
        Path.dirname(elixir_lib),
        "-pa",
        Path.join(elixir_lib, "ebin"),
        minga_ebin,
        "-s",
        "elixir",
        "start_cli",
        "-extra",
        "-e",
        code,
        "--" | args
      ],
      opts
    )
  end
end
