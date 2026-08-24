defmodule PumbleAutomation.Contract.Pumble.ManifestTest do
  @moduledoc """
  Rendered manifest keys match matrix M-1..M-8 and M-10. Secrets cannot appear.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Pumble.Manifest
  alias PumbleAutomation.Pumble.Payload
  alias PumbleAutomation.PumbleFake

  test "served manifest keys, events, and secret stripping match the fixture" do
    spec = PumbleFake.fixture("manifest/served.json")
    rendered = Manifest.build() |> Manifest.render()
    json = Manifest.build() |> Manifest.to_json()

    for key <- spec["required_top_level_keys"] do
      assert Map.has_key?(rendered, key), "missing served key #{key}"
    end

    for key <- spec["forbidden_keys"] ++ spec["product_omitted_keys"] do
      refute Map.has_key?(rendered, key), "served manifest leaked #{key}"
    end

    pumble = Application.fetch_env!(:pumble_automation, :pumble)

    for secret <- [
          Keyword.fetch!(pumble, :app_key),
          Keyword.fetch!(pumble, :client_secret),
          Keyword.fetch!(pumble, :signing_secret)
        ] do
      refute json =~ secret
    end

    assert rendered["eventSubscriptions"]["events"] == spec["events"]
    assert rendered["eventSubscriptions"]["events"] == Payload.event_types()

    assert [%{"command" => "/workflow"}] = rendered["slashCommands"]

    types = Enum.map(rendered["shortcuts"], & &1["shortcutType"])
    assert types == ["GLOBAL", "ON_MESSAGE"]

    assert rendered["dynamicMenus"] == [
             %{"onAction" => "pick_workflow", "url" => rendered["eventSubscriptions"]["url"]}
           ]

    assert rendered["id"] == "test-client-id"
    assert rendered["name"] == "workflow-automation"
    assert rendered["displayName"] == "Workflow Automation"
    assert rendered["bot"] == true
    assert rendered["botTitle"] == "Workflow Automation Bot"
    assert rendered["socketMode"] == false
    assert rendered["defaultHomeView"] == %{"enabled" => false, "blocks" => []}
    assert json =~ "test-client-id"
  end

  test "matrix M-rows named by the catalog exist in the source matrix" do
    matrix = File.read!("docs/evidence/pumble_source_matrix.md")
    [entry] = Enum.filter(PumbleFake.catalog()["fixtures"], &(&1["kind"] == "manifest"))

    for row <- entry["source"]["matrix"] do
      assert matrix =~ "| #{row} |", "source matrix is missing #{row}"
    end
  end
end
