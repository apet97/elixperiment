defmodule PumbleAutomation.Contract.Pumble.CatalogTest do
  @moduledoc """
  Provenance, completeness, and secret hygiene for every stored Pumble fixture.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.PumbleFake

  @sacrificial_workspace_sha256 "51e6c88805f5683b953c318954f6626c0ed574c94ec3a984adcfb2baf76e6d98"

  @forbidden_substrings [
    "Bearer ",
    "xoxb-",
    "xoxp-",
    "sk_live",
    "-----BEGIN"
  ]

  test "every JSON fixture has a catalog row with provenance" do
    catalog = PumbleFake.catalog()
    listed = catalog["fixtures"] |> Enum.map(& &1["path"]) |> Enum.sort()
    on_disk = json_fixture_paths() |> Enum.sort()

    assert listed == on_disk

    for entry <- catalog["fixtures"] do
      assert is_list(entry["source"]["matrix"]) and entry["source"]["matrix"] != []
      assert entry["source"]["document"] == "docs/evidence/pumble_source_matrix.md"
      assert entry["fields_sanitized"] == true
      assert entry["shape_status"] in ["SUPPORTED", "INFERRED", "PROBE"]
      assert entry["kind"] in ["callback", "oauth", "signature", "api_request", "manifest"]
    end
  end

  test "OAuth error field names stay probe-tagged and are not promoted" do
    [entry] =
      Enum.filter(PumbleFake.catalog()["fixtures"], fn row ->
        row["path"] == "oauth/exchange_error.json"
      end)

    assert entry["shape_status"] == "PROBE"
    assert entry["live_probe"] == "PR-15"
  end

  test "fixtures contain no live credentials, tokens, or sacrificial workspace id" do
    root = PumbleFake.fixtures_root()

    offenders =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        contents = File.read!(path)

        ((@forbidden_substrings
          |> Enum.filter(&String.contains?(contents, &1))) ++ workspace_matches(contents))
        |> Enum.uniq()
        |> Enum.map(&{Path.relative_to(path, root), &1})
      end)

    assert offenders == []
  end

  defp workspace_matches(contents) do
    ~r/(?<![0-9a-f])[0-9a-f]{24}(?![0-9a-f])/
    |> Regex.scan(contents)
    |> List.flatten()
    |> Enum.filter(fn candidate ->
      :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower) ==
        @sacrificial_workspace_sha256
    end)
  end

  test "gitleaks reports no leaks in the fixture tree when the scanner is installed" do
    case System.find_executable("gitleaks") do
      nil ->
        :ok

      executable ->
        {output, status} =
          System.cmd(
            executable,
            [
              "detect",
              "--no-git",
              "--redact",
              "--source",
              PumbleFake.fixtures_root()
            ],
            stderr_to_stdout: true,
            env: [{"PATH", System.get_env("PATH", "")}]
          )

        assert status == 0, output
    end
  end

  defp json_fixture_paths do
    root = PumbleFake.fixtures_root()

    root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&(&1 == "catalog.json"))
  end
end
