defmodule Minga.Tool.Installer.GitHubReleaseTest do
  use ExUnit.Case, async: true

  alias Minga.Tool.Installer.GitHubRelease

  describe "platform_suffix/0" do
    test "returns a string with os_arch format" do
      suffix = GitHubRelease.platform_suffix()
      assert is_binary(suffix)
      assert String.contains?(suffix, "_")
    end

    test "returns valid os and arch components" do
      suffix = GitHubRelease.platform_suffix()
      [os, arch] = String.split(suffix, "_", parts: 2)
      assert os in ["darwin", "linux", "windows", "unknown"]
      assert arch in ["arm64", "amd64"]
    end
  end
end
