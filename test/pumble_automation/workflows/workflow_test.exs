defmodule PumbleAutomation.Workflows.WorkflowTest do
  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Workflow
  alias PumbleAutomation.Workflows.WorkflowVersion

  setup do
    %{installation: %{id: installation_id}, member: member} = InstallationsFixtures.install()
    %{installation_id: installation_id, member: member}
  end

  describe "the migration" do
    test "creates the workflows table with its tenant uniqueness" do
      assert %{rows: [[found]]} = Repo.query!("SELECT to_regclass('public.workflows')::text")
      assert found == "workflows"

      definitions = index_definitions("workflows")
      assert definitions =~ "UNIQUE"
      assert definitions =~ "(installation_id, slug)"
      assert definitions =~ "(installation_id, status)"
    end
  end

  describe "changeset/2" do
    test "requires a tenant, a name, and a status", %{installation_id: _installation_id} do
      changeset = Workflow.changeset(%Workflow{}, %{})

      assert %{installation_id: ["can't be blank"], name: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "bounds the name and the description", %{installation_id: installation_id} do
      long_name = String.duplicate("n", Workflow.name_max() + 1)
      long_description = String.duplicate("d", Workflow.description_max() + 1)

      changeset =
        Workflow.changeset(%Workflow{}, %{
          installation_id: installation_id,
          name: long_name,
          description: long_description,
          status: "draft"
        })

      assert %{name: [_], description: [_]} = errors_on(changeset)

      assert %{name: [_]} =
               errors_on(
                 Workflow.changeset(%Workflow{}, %{
                   installation_id: installation_id,
                   name: "",
                   status: "draft"
                 })
               )
    end

    test "bounds the slug and its shape", %{installation_id: installation_id} do
      for slug <- ["Deploy", "-deploy", "deploy alias", String.duplicate("a", 65)] do
        changeset =
          Workflow.changeset(%Workflow{}, %{
            installation_id: installation_id,
            name: "Deploy",
            slug: slug,
            status: "draft"
          })

        assert %{slug: [_ | _]} = errors_on(changeset)
      end
    end

    test "refuses a status outside the set", %{installation_id: installation_id} do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          installation_id: installation_id,
          name: "Deploy",
          status: "running"
        })

      assert %{status: [_]} = errors_on(changeset)
      assert Workflow.statuses() == ~w(draft active inactive archived)
    end

    test "refuses a draft that is not a definition", %{installation_id: installation_id} do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          installation_id: installation_id,
          name: "Deploy",
          status: "draft",
          draft_definition: %{"schema_version" => 9, "trigger" => %{}, "steps" => []}
        })

      assert %{draft_definition: [_]} = errors_on(changeset)
    end

    test "stores a valid draft in its canonical shape", %{installation_id: installation_id} do
      definition = definition([message_node()])

      workflow =
        workflow(installation_id, %{
          draft_definition:
            definition |> Definition.encode() |> Jason.encode!() |> Jason.decode!()
        })

      assert {:ok, decoded} = Workflow.draft(workflow)
      assert decoded == definition
    end
  end

  describe "tenant scope" do
    test "one slug is unique inside an installation", %{installation_id: installation_id} do
      workflow(installation_id, %{slug: "deploy"})

      duplicate =
        Workflow.changeset(%Workflow{}, %{
          installation_id: installation_id,
          name: "Deploy again",
          slug: "deploy",
          status: "draft"
        })

      assert {:error, changeset} = Repo.insert(duplicate)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "the same slug is free in another installation", %{installation_id: installation_id} do
      %{installation: other} = InstallationsFixtures.install()

      first = workflow(installation_id, %{slug: "deploy"})
      second = workflow(other.id, %{slug: "deploy"})

      assert first.slug == second.slug
      refute first.installation_id == second.installation_id
    end

    test "any number of workflows may have no slug", %{installation_id: installation_id} do
      assert workflow(installation_id, %{slug: nil})
      assert workflow(installation_id, %{slug: nil})
    end

    test "a save cannot reach a workflow through another installation", %{
      installation_id: installation_id
    } do
      %{installation: other} = InstallationsFixtures.install()
      workflow = workflow(installation_id)

      assert {:error, %Error{class: :not_found, code: :workflow_not_found}} =
               Workflow.save_draft(
                 %{workflow | installation_id: other.id},
                 definition([stop_node()]),
                 0
               )

      assert Repo.get!(Workflow, workflow.id).draft_revision == 0
    end
  end

  describe "save_draft/4" do
    setup %{installation_id: installation_id} do
      %{workflow: workflow(installation_id)}
    end

    test "writes the draft and moves the revision on", %{workflow: workflow, member: member} do
      definition = definition([message_node()])

      assert {:ok, saved} =
               Workflow.save_draft(workflow, definition, 0, updated_by_member_id: member.id)

      assert saved.draft_revision == 1
      assert saved.updated_by_member_id == member.id
      assert {:ok, ^definition} = Workflow.draft(saved)

      assert {:ok, again} = Workflow.save_draft(saved, definition, 1)
      assert again.draft_revision == 2
    end

    test "accepts a plain map and stores the canonical shape", %{workflow: workflow} do
      definition = definition([delay_node()])
      raw = definition |> Definition.encode() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, saved} = Workflow.save_draft(workflow, raw, 0)
      assert saved.draft_definition == Definition.encode(definition)
    end

    test "refuses a stale revision and names the current one", %{workflow: workflow} do
      {:ok, saved} = Workflow.save_draft(workflow, definition([stop_node()]), 0)

      assert {:error, %Error{class: :conflict, code: :draft_revision_conflict} = error} =
               Workflow.save_draft(workflow, definition([delay_node()]), 0)

      assert error.details == %{expected_revision: 0, current_revision: 1}

      # The first save is still the one that is stored.
      assert {:ok, stored} = Workflow.draft(Repo.get!(Workflow, workflow.id))
      assert {:ok, ^stored} = Workflow.draft(saved)
    end

    test "detects the lost update between two editors", %{workflow: workflow} do
      editor_one = Repo.get!(Workflow, workflow.id)
      editor_two = Repo.get!(Workflow, workflow.id)

      assert {:ok, _saved} = Workflow.save_draft(editor_one, definition([stop_node()]), 0)

      assert {:error, %Error{code: :draft_revision_conflict}} =
               Workflow.save_draft(editor_two, definition([message_node()]), 0)
    end

    test "refuses a malformed draft before it reaches the database", %{workflow: workflow} do
      assert {:error, %Error{class: :validation, code: :unsupported_schema_version}} =
               Workflow.save_draft(workflow, %{"schema_version" => 2}, 0)

      assert {:error, %Error{class: :validation}} = Workflow.save_draft(workflow, "draft", 0)
      assert Repo.get!(Workflow, workflow.id).draft_definition == nil
    end

    test "refuses a draft larger than the definition size limit", %{workflow: workflow} do
      wide_text = String.duplicate("x", 16_000)

      steps =
        Enum.map(1..20, fn _ ->
          message_node() |> Map.update!(:config, &%{&1 | text: wide_text})
        end)

      assert {:error, %Error{class: :validation, code: :definition_too_large} = error} =
               Workflow.save_draft(workflow, definition(steps), 0)

      assert error.details.limit == 256 * 1024
      assert Repo.get!(Workflow, workflow.id).draft_definition == nil
    end

    test "leaves the active version and the status alone", %{workflow: workflow} do
      # A real version, not an invented identifier: since `20260815000005`
      # `active_version_id` is a foreign key into `workflow_versions`.
      {:ok, %{id: active_version_id}} =
        WorkflowVersion.create(workflow, %{source_definition: definition()})

      {:ok, activated} =
        workflow
        |> Workflow.changeset(%{active_version_id: active_version_id, status: "active"})
        |> Repo.update()

      assert {:ok, saved} = Workflow.save_draft(activated, definition([message_node()]), 0)

      assert saved.active_version_id == active_version_id
      assert saved.status == "active"
      assert saved.draft_revision == 1
    end

    test "reports a workflow that no longer exists", %{workflow: workflow} do
      Repo.delete!(workflow)

      assert {:error, %Error{class: :not_found, code: :workflow_not_found}} =
               Workflow.save_draft(workflow, definition([stop_node()]), 0)
    end
  end

  describe "draft/1" do
    test "says when a workflow has no draft yet", %{installation_id: installation_id} do
      assert {:error, %Error{class: :not_found, code: :draft_not_found}} =
               installation_id |> workflow() |> Workflow.draft()
    end
  end

  defp index_definitions(table) do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table])

    rows |> List.flatten() |> Enum.join("\n")
  end
end
