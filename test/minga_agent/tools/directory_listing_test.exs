defmodule MingaAgent.Tools.DirectoryListingTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tools.DirectoryListing

  test "formats directories before files and sorts each group alphabetically" do
    entries = [
      %{name: "zeta.txt", type: :file},
      %{name: "beta", type: :directory},
      %{name: "alpha.txt", type: :file},
      %{name: "alpha", type: :directory}
    ]

    assert DirectoryListing.format_entries(entries) == "alpha/\nbeta/\nalpha.txt\nzeta.txt"
  end

  test "keeps ordinary hidden files while omitting secret files" do
    entries = [
      %{name: ".hidden", type: :file},
      %{name: ".env.local", type: :file},
      %{name: ".npmrc", type: :file}
    ]

    assert DirectoryListing.format_entries(entries) == ".hidden"
  end

  test "omits generated and dependency directories" do
    ignored = [
      "_build",
      ".build",
      ".git",
      ".elixir_ls",
      ".expert",
      "deps",
      "node_modules",
      "DerivedData",
      "tmp"
    ]

    entries = [
      %{name: "lib", type: :directory} | Enum.map(ignored, &%{name: &1, type: :directory})
    ]

    assert DirectoryListing.format_entries(entries) == "lib/"
  end

  test "caps large listings" do
    entries =
      Enum.map(
        1..505,
        &%{name: "file_#{String.pad_leading(Integer.to_string(&1), 3, "0")}.txt", type: :file}
      )

    lines = entries |> DirectoryListing.format_entries() |> String.split("\n")

    assert Enum.count(lines) == 501
    assert List.last(lines) == "... (truncated, 5 more entries)"
  end
end
