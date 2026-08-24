defmodule PumbleAutomation.WorkflowsTest do
  use PumbleAutomation.DataCase, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Error
  alias PumbleAutomation.InstallationsFixtures
  alias PumbleAutomation.Scope
  alias PumbleAutomation.Workflows
  alias PumbleAutomation.Workflows.Definition
  alias PumbleAutomation.Workflows.Definition.Trigger
  alias PumbleAutomation.Workflows.ManualAlias
  alias PumbleAutomation.Workflows.StarterTemplates
  alias PumbleAutomation.Workflows.TriggerBinding
  alias PumbleAutomation.Workflows.Workflow

  setup do
    here = InstallationsFixtures.install()
    there = InstallationsFixtures.install()

    %{
      scope: Scope.new(here.member),
      other_scope: Scope.new(there.member),
      installation_id: here.installation.id,
      other_installation_id: there.installation.id
    }
  end

  describe "the public surface" do
    test "every public function takes a scope first" do
      for {name, arity} <- Workflows.__info__(:functions), not internal?(name) do
        assert scope_first?(name, arity), "#{name}/#{arity} does not require a scope"
      end
    end

    test "there is no unscoped get" do
      exported = Workflows.__info__(:functions)

      refute Keyword.get(exported, :get) == 1
      refute Keyword.get(exported, :get_workflow) == 1
    end
  end

  describe "list_workflows/2" do
    test "returns only this workspace's workflows", %{
      scope: scope,
      installation_id: installation_id,
      other_installation_id: other_installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})
      _theirs = workflow(other_installation_id, %{name: "Theirs"})

      assert {:ok, [found]} = Workflows.list_workflows(scope)
      assert found.id == mine.id
    end

    test "sees nothing of another workspace even when it is full", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      for index <- 1..3, do: workflow(installation_id, %{name: "Mine #{index}"})

      assert {:ok, []} = Workflows.list_workflows(other_scope)
    end

    test "costs one query however many rows it returns", %{
      scope: scope,
      installation_id: installation_id
    } do
      for index <- 1..10, do: workflow(installation_id, %{name: "Mine #{index}"})

      {result, queries} = count_queries(fn -> Workflows.list_workflows(scope) end)

      assert {:ok, workflows} = result
      assert length(workflows) == 10
      assert queries == 1
    end

    test "hides archived workflows unless asked", %{
      scope: scope,
      installation_id: installation_id
    } do
      workflow(installation_id, %{
        name: "Old",
        status: "archived",
        archived_at: DateTime.utc_now()
      })

      assert {:ok, []} = Workflows.list_workflows(scope)
      assert {:ok, [_archived]} = Workflows.list_workflows(scope, include_archived: true)
    end

    test "bounds the page size", %{scope: scope, installation_id: installation_id} do
      for index <- 1..5, do: workflow(installation_id, %{name: "Mine #{index}"})

      assert {:ok, page} = Workflows.list_workflows(scope, limit: 2)
      assert length(page) == 2
    end

    test "a viewer may read", %{installation_id: installation_id} do
      workflow(installation_id, %{name: "Mine"})
      viewer = viewer_scope(installation_id)

      assert {:ok, [_workflow]} = Workflows.list_workflows(viewer)
    end

    test "search matches name without scanning other tenants", %{
      scope: scope,
      installation_id: installation_id,
      other_installation_id: other_installation_id
    } do
      mine = workflow(installation_id, %{name: "Nightly digest"})
      _other = workflow(installation_id, %{name: "Welcome"})
      _theirs = workflow(other_installation_id, %{name: "Nightly digest"})

      assert {:ok, [found]} = Workflows.list_workflows(scope, q: "nightly")
      assert found.id == mine.id
    end
  end

  describe "list_workflow_index/2" do
    test "returns summary rows without draft documents", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = drafted_workflow(installation_id, %{name: "Nightly digest"})

      assert {:ok, %{entries: [row], total: 1}} = Workflows.list_workflow_index(scope)
      assert row.id == mine.id
      assert row.name == "Nightly digest"
      assert row.status == "draft"
      assert row.trigger_summary == "Pumble · New message"
      assert row.validation_state == "draft"
      refute Map.has_key?(row, :draft_definition)
    end

    test "keeps the live alias searchable while identifying a pending draft alias", %{
      scope: scope,
      installation_id: installation_id
    } do
      workflow =
        drafted_workflow(installation_id, %{
          slug: "live-route",
          draft_definition: Definition.encode(manual_definition("live-route", [delay_node()]))
        })

      assert {:ok, activation} = Workflows.activate_workflow(scope, workflow.id, 0)

      assert {:ok, saved} =
               Workflows.update_draft(
                 scope,
                 workflow.id,
                 manual_definition("pending-route", [delay_node()]),
                 activation.workflow.draft_revision
               )

      assert saved.status == "active"
      assert saved.slug == "pending-route"

      assert {:ok, %{entries: [live_row], total: 1}} =
               Workflows.list_workflow_index(scope, q: "live-route")

      assert live_row.live_alias == "live-route"
      assert live_row.pending_draft_alias == "pending-route"
      assert is_nil(live_row.editable_alias)
      assert live_row.trigger_summary == "Manual · live-route"

      assert {:ok, %{entries: [pending_row], total: 1}} =
               Workflows.list_workflow_index(scope, q: "pending-route")

      assert pending_row.id == workflow.id
    end

    test "keeps an archived binding immutable but presents its aliases as non-live", %{
      scope: scope,
      installation_id: installation_id
    } do
      workflow =
        drafted_workflow(installation_id, %{
          slug: "live-route",
          draft_definition: Definition.encode(manual_definition("live-route", [delay_node()]))
        })

      assert {:ok, activation} = Workflows.activate_workflow(scope, workflow.id, 0)

      assert {:ok, _saved} =
               Workflows.update_draft(
                 scope,
                 workflow.id,
                 manual_definition("pending-route", [delay_node()]),
                 activation.workflow.draft_revision
               )

      binding_before =
        Repo.one!(
          from binding in TriggerBinding,
            where: binding.workflow_version_id == ^activation.version.id
        )

      assert {:ok, archived} = Workflows.archive_workflow(scope, workflow.id)
      assert archived.active_version_id == activation.version.id
      assert Repo.get!(TriggerBinding, binding_before.id) == binding_before

      assert {:ok, %{entries: [row], total: 1}} =
               Workflows.list_workflow_index(scope,
                 include_archived: true,
                 q: "live-route"
               )

      assert row.status == "archived"
      assert row.validation_state == "draft"
      assert is_nil(row.live_alias)
      assert is_nil(row.pending_draft_alias)
      assert row.editable_alias == "pending-route"
      assert row.trigger_summary == "Manual · live-route"

      assert {:ok, %{entries: [pending], total: 1}} =
               Workflows.list_workflow_index(scope,
                 include_archived: true,
                 q: "pending-route"
               )

      assert pending.id == workflow.id
    end

    test "costs two queries however many rows it returns", %{
      scope: scope,
      installation_id: installation_id
    } do
      for index <- 1..10, do: workflow(installation_id, %{name: "Mine #{index}"})

      {result, queries} = count_queries(fn -> Workflows.list_workflow_index(scope) end)

      assert {:ok, %{entries: entries, total: 10}} = result
      assert length(entries) == 10
      assert queries == 2
    end

    test "paginates without loading another tenant's rows", %{
      scope: scope,
      installation_id: installation_id,
      other_installation_id: other_installation_id
    } do
      for index <- 1..3, do: workflow(installation_id, %{name: "Mine #{index}"})
      workflow(other_installation_id, %{name: "Theirs"})

      assert {:ok, %{entries: page, total: 3}} =
               Workflows.list_workflow_index(scope, limit: 2, offset: 0)

      assert length(page) == 2
    end
  end

  describe "get_workflow/2" do
    test "returns this workspace's workflow", %{scope: scope, installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:ok, found} = Workflows.get_workflow(scope, mine.id)
      assert found.id == mine.id
    end

    test "answers not_found for another workspace's workflow", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:error, error} = Workflows.get_workflow(other_scope, mine.id)
      assert error == unknown_id_error(other_scope)
    end

    test "answers not_found for a malformed identifier", %{scope: scope} do
      assert {:error, %Error{class: :not_found}} = Workflows.get_workflow(scope, "not-a-uuid")
    end
  end

  describe "create_workflow/2" do
    test "creates inside the scope's workspace and records the author", %{
      scope: scope,
      installation_id: installation_id
    } do
      assert {:ok, created} = Workflows.create_workflow(scope, %{name: "Deploy announcements"})

      assert created.installation_id == installation_id
      assert created.created_by_member_id == scope.member_id
      assert created.status == "draft"
    end

    test "ignores an installation the caller tries to name", %{
      scope: scope,
      installation_id: installation_id,
      other_installation_id: other_installation_id
    } do
      assert {:ok, created} =
               Workflows.create_workflow(scope, %{
                 name: "Sneaky",
                 installation_id: other_installation_id
               })

      assert created.installation_id == installation_id
    end

    test "writes the audit row in the same transaction", %{
      scope: scope,
      installation_id: installation_id
    } do
      assert {:ok, created} = Workflows.create_workflow(scope, %{name: "Deploy"})

      assert [event] = audit_events(installation_id, "workflow.created")
      assert event.resource_id == created.id
      assert event.actor_id == scope.member_id
      assert event.actor_type == "user"
    end

    test "leaves no workflow and no audit row when the workflow is invalid", %{
      scope: scope,
      installation_id: installation_id
    } do
      assert {:error, %Error{class: :validation}} = Workflows.create_workflow(scope, %{name: ""})

      assert [] == audit_events(installation_id, "workflow.created")
      assert {:ok, []} = Workflows.list_workflows(scope)
    end

    test "reports a slug already used in this workspace", %{scope: scope} do
      assert {:ok, _first} = Workflows.create_workflow(scope, %{name: "One", slug: "deploy"})

      assert {:error, %Error{class: :conflict, code: :slug_taken}} =
               Workflows.create_workflow(scope, %{name: "Two", slug: "deploy"})
    end

    test "a viewer may not", %{installation_id: installation_id} do
      viewer = viewer_scope(installation_id)

      assert {:error, %Error{class: :permission}} =
               Workflows.create_workflow(viewer, %{name: "Deploy"})
    end

    test "stores a first-party template as an ordinary draft", %{scope: scope} do
      definition = StarterTemplates.blank()

      assert {:ok, created} =
               Workflows.create_workflow(scope, %{name: "Blank", definition: definition})

      assert {:ok, stored} = Workflow.draft(created)
      assert stored.trigger.id == definition.trigger.id
    end

    test "uses one alias for a manual draft and its workflow row", %{scope: scope} do
      assert {:ok, created} =
               Workflows.create_workflow(scope, %{
                 name: "Deploy",
                 slug: "deploy",
                 definition: StarterTemplates.blank()
               })

      assert created.slug == "deploy"
      assert {:ok, stored} = Workflow.draft(created)
      assert stored.trigger.type == :manual
      assert stored.trigger.config.manual_alias == "deploy"
    end

    test "does not persist a manual alias for a non-manual draft", %{scope: scope} do
      assert {:ok, definition} = StarterTemplates.fetch("welcome")

      assert {:ok, created} =
               Workflows.create_workflow(scope, %{
                 name: "Welcome",
                 slug: "misleading",
                 definition: definition
               })

      assert is_nil(created.slug)
      assert {:ok, stored} = Workflow.draft(created)
      assert stored.trigger.type == :pumble_event
    end

    test "reports an invalid manual alias as validation, not a collision", %{scope: scope} do
      assert {:error, %Error{class: :validation, code: :invalid_manual_alias} = error} =
               Workflows.create_workflow(scope, %{
                 name: "Deploy",
                 slug: "Not valid",
                 definition: StarterTemplates.blank()
               })

      assert error.message == ManualAlias.message()
      assert {:ok, []} = Workflows.list_workflows(scope)
    end

    test "normalizes explicit, struct, and raw manual aliases identically", %{scope: scope} do
      cases = [
        {"Explicit", %{slug: "  explicit-route  ", definition: StarterTemplates.blank()},
         "explicit-route"},
        {"Struct", %{definition: manual_definition("  struct-route  ")}, "struct-route"},
        {"Raw", %{definition: Definition.encode(manual_definition("  raw-route  "))}, "raw-route"}
      ]

      for {name, attrs, expected_alias} <- cases do
        assert {:ok, created} = Workflows.create_workflow(scope, Map.put(attrs, :name, name))
        assert created.slug == expected_alias
        assert {:ok, stored} = Workflow.draft(created)
        assert stored.trigger.config.manual_alias == expected_alias
      end
    end

    test "returns the same typed error for explicit, struct, and raw invalid aliases", %{
      scope: scope
    } do
      cases = [
        {"Explicit", %{slug: "Not valid", definition: StarterTemplates.blank()}},
        {"Struct", %{definition: manual_definition("Not valid")}},
        {"Raw", %{definition: Definition.encode(manual_definition("Not valid"))}}
      ]

      for {name, attrs} <- cases do
        assert {:error, %Error{class: :validation, code: :invalid_manual_alias} = error} =
                 Workflows.create_workflow(scope, Map.put(attrs, :name, name))

        assert error.message == ManualAlias.message()
      end

      assert {:ok, []} = Workflows.list_workflows(scope)
    end
  end

  describe "duplicate_workflow/2" do
    test "creates a draft with new workflow, trigger, and node ids", %{
      scope: scope,
      installation_id: installation_id
    } do
      source =
        drafted_workflow(installation_id, %{
          name: "Source",
          slug: "source-alias",
          draft_definition: Definition.encode(definition([message_node()]))
        })

      {:ok, source_def} = Workflow.draft(source)
      _version = version(source)

      assert {:ok, copy} = Workflows.duplicate_workflow(scope, source.id)
      assert {:ok, copy_def} = Workflow.draft(copy)

      assert copy.id != source.id
      assert copy.status == "draft"
      assert is_nil(copy.active_version_id)
      assert copy_def.trigger.id != source_def.trigger.id
      assert Definition.node_ids(source_def) != []

      assert MapSet.disjoint?(
               MapSet.new(Definition.node_ids(source_def)),
               MapSet.new(Definition.node_ids(copy_def))
             )

      assert {:ok, []} = Workflows.list_versions(scope, copy.id)
      assert {:ok, [_version]} = Workflows.list_versions(scope, source.id)
    end

    test "answers not_found across workspaces", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:error, error} = Workflows.duplicate_workflow(other_scope, mine.id)
      assert error == unknown_id_error(other_scope)
    end

    test "a viewer may not", %{installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})
      viewer = viewer_scope(installation_id)

      assert {:error, %Error{class: :permission}} = Workflows.duplicate_workflow(viewer, mine.id)
    end
  end

  describe "update_draft/4" do
    test "saves the draft and moves the revision", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:ok, saved} = Workflows.update_draft(scope, mine.id, definition(), 0)

      assert saved.draft_revision == 1
      assert saved.updated_by_member_id == scope.member_id
    end

    test "refuses to overwrite a draft somebody else saved first", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:ok, _saved} = Workflows.update_draft(scope, mine.id, definition(), 0)

      assert {:error, %Error{class: :conflict, code: :draft_revision_conflict} = error} =
               Workflows.update_draft(scope, mine.id, definition([message_node()]), 0)

      assert error.details.current_revision == 1
    end

    test "changes the workflow slug with a manual trigger alias", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine =
        drafted_workflow(installation_id, %{
          slug: "old-alias",
          draft_definition: Definition.encode(manual_definition("old-alias"))
        })

      assert {:ok, saved} =
               Workflows.update_draft(scope, mine.id, manual_definition("new-alias"), 0)

      assert saved.slug == "new-alias"
      assert {:ok, stored} = Workflow.draft(saved)
      assert stored.trigger.config.manual_alias == "new-alias"
    end

    test "normalizes struct and raw draft aliases identically", %{
      scope: scope,
      installation_id: installation_id
    } do
      cases = [
        {"struct-route", manual_definition("  struct-route  ")},
        {"raw-route", Definition.encode(manual_definition("  raw-route  "))}
      ]

      for {expected_alias, input} <- cases do
        mine =
          drafted_workflow(installation_id, %{
            slug: "old-#{expected_alias}",
            draft_definition: Definition.encode(manual_definition("old-#{expected_alias}"))
          })

        assert {:ok, saved} = Workflows.update_draft(scope, mine.id, input, 0)
        assert saved.slug == expected_alias
        assert {:ok, stored} = Workflow.draft(saved)
        assert stored.trigger.config.manual_alias == expected_alias
      end
    end

    test "clears the workflow slug when the trigger is no longer manual", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine =
        drafted_workflow(installation_id, %{
          slug: "deploy",
          draft_definition: Definition.encode(manual_definition("deploy"))
        })

      assert {:ok, saved} = Workflows.update_draft(scope, mine.id, definition(), 0)

      assert is_nil(saved.slug)
      assert {:ok, stored} = Workflow.draft(saved)
      assert stored.trigger.type == :pumble_event
    end

    test "returns slug_taken without changing either alias", %{
      scope: scope,
      installation_id: installation_id
    } do
      _taken =
        drafted_workflow(installation_id, %{
          slug: "deploy",
          draft_definition: Definition.encode(manual_definition("deploy"))
        })

      mine =
        drafted_workflow(installation_id, %{
          slug: "release",
          draft_definition: Definition.encode(manual_definition("release"))
        })

      assert {:error, %Error{class: :conflict, code: :slug_taken}} =
               Workflows.update_draft(scope, mine.id, manual_definition("deploy"), 0)

      stored = Repo.get!(Workflow, mine.id)
      assert stored.slug == "release"
      assert stored.draft_revision == 0
      assert {:ok, definition} = Workflow.draft(stored)
      assert definition.trigger.config.manual_alias == "release"
    end

    test "reports a locally invalid draft alias without claiming it is taken", %{
      scope: scope,
      installation_id: installation_id
    } do
      inputs = [
        manual_definition("Not valid"),
        Definition.encode(manual_definition("Not valid"))
      ]

      for {input, index} <- Enum.with_index(inputs, 1) do
        original_alias = "release-#{index}"

        mine =
          drafted_workflow(installation_id, %{
            slug: original_alias,
            draft_definition: Definition.encode(manual_definition(original_alias))
          })

        assert {:error, %Error{class: :validation, code: :invalid_manual_alias} = error} =
                 Workflows.update_draft(scope, mine.id, input, 0)

        assert error.message == ManualAlias.message()
        assert Repo.get!(Workflow, mine.id).slug == original_alias
      end
    end

    test "a stale alias edit changes neither the draft nor the slug", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine =
        drafted_workflow(installation_id, %{
          slug: "old-alias",
          draft_definition: Definition.encode(manual_definition("old-alias"))
        })

      assert {:ok, _saved} =
               Workflows.update_draft(scope, mine.id, manual_definition("winner"), 0)

      assert {:error, %Error{class: :conflict, code: :draft_revision_conflict}} =
               Workflows.update_draft(scope, mine.id, manual_definition("stale"), 0)

      stored = Repo.get!(Workflow, mine.id)
      assert stored.slug == "winner"
      assert stored.draft_revision == 1
      assert {:ok, definition} = Workflow.draft(stored)
      assert definition.trigger.config.manual_alias == "winner"
    end

    test "answers not_found across workspaces", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:error, error} = Workflows.update_draft(other_scope, mine.id, definition(), 0)
      assert error == unknown_id_error(other_scope)
    end

    test "a viewer may not", %{installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})
      viewer = viewer_scope(installation_id)

      assert {:error, %Error{class: :permission}} =
               Workflows.update_draft(viewer, mine.id, definition(), 0)
    end
  end

  defp manual_definition(alias_name, steps \\ []) do
    Definition.new(
      Trigger.new(:manual, %{manual_alias: alias_name, slash_command: true}),
      steps
    )
  end

  describe "archive_workflow/2" do
    test "archives and audits", %{scope: scope, installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:ok, archived} = Workflows.archive_workflow(scope, mine.id)

      assert archived.status == "archived"
      assert archived.archived_at

      assert [event] = audit_events(installation_id, "workflow.archived")
      assert event.metadata["next_state"] == "archived"
    end

    test "refuses to archive twice", %{scope: scope, installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:ok, _archived} = Workflows.archive_workflow(scope, mine.id)

      assert {:error, %Error{class: :conflict, code: :already_archived}} =
               Workflows.archive_workflow(scope, mine.id)
    end

    test "answers not_found across workspaces", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:error, error} = Workflows.archive_workflow(other_scope, mine.id)
      assert error == unknown_id_error(other_scope)
      assert Repo.get!(Workflow, mine.id).status == "draft"
    end

    test "a viewer may not", %{installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})
      viewer = viewer_scope(installation_id)

      assert {:error, %Error{class: :permission}} = Workflows.archive_workflow(viewer, mine.id)
    end
  end

  describe "delete_workflow/2" do
    test "deletes, audits, and takes the versions with it", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = drafted_workflow(installation_id, %{name: "Mine"})
      _version = version(mine)

      assert {:ok, _deleted} = Workflows.delete_workflow(scope, mine.id)

      refute Repo.get(Workflow, mine.id)
      assert [event] = audit_events(installation_id, "workflow.deleted")
      assert event.resource_id == mine.id
    end

    test "answers not_found across workspaces and deletes nothing", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})
      owner = owner_scope(other_scope.installation_id)

      assert {:error, error} = Workflows.delete_workflow(owner, mine.id)
      assert error == unknown_id_error(owner)
      assert Repo.get(Workflow, mine.id)
    end

    test "an editor may not", %{installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})
      editor = editor_scope(installation_id)

      assert {:error, %Error{class: :permission}} = Workflows.delete_workflow(editor, mine.id)
      assert Repo.get(Workflow, mine.id)
    end
  end

  describe "delete_draft_workflow/2" do
    test "deletes a never-activated draft", %{scope: scope, installation_id: installation_id} do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:ok, _} = Workflows.delete_draft_workflow(scope, mine.id)
      refute Repo.get(Workflow, mine.id)
    end

    test "refuses a workflow that is no longer a draft", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Live", status: "inactive"})

      assert {:error, %Error{class: :conflict, code: :not_a_draft}} =
               Workflows.delete_draft_workflow(scope, mine.id)

      assert Repo.get(Workflow, mine.id)
    end
  end

  describe "deactivate_workflow/2" do
    test "a draft is not running and says so in a typed error", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:error, %Error{class: :conflict, code: :not_active}} =
               Workflows.deactivate_workflow(scope, mine.id)
    end

    test "answers not_found across workspaces before saying anything else", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = workflow(installation_id, %{name: "Mine"})

      assert {:error, error} = Workflows.deactivate_workflow(other_scope, mine.id)
      assert error == unknown_id_error(other_scope)
    end
  end

  describe "list_versions/2 and get_version/3" do
    test "list the workflow's versions, newest first", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = drafted_workflow(installation_id, %{name: "Mine"})
      first = version(mine)
      second = version(mine, %{source_definition: definition([message_node()])})

      assert {:ok, history} = Workflows.list_versions(scope, mine.id)

      assert Enum.map(history, & &1.version_number) == [2, 1]
      assert Enum.map(history, & &1.id) == [second.id, first.id]
      refute Map.has_key?(hd(history), :source_definition)
    end

    test "get one version by its number", %{scope: scope, installation_id: installation_id} do
      mine = drafted_workflow(installation_id, %{name: "Mine"})
      created = version(mine)

      assert {:ok, found} = Workflows.get_version(scope, mine.id, 1)
      assert found.id == created.id
      assert found.source_definition == mine.draft_definition
    end

    test "answer not_found for a version number nobody has", %{
      scope: scope,
      installation_id: installation_id
    } do
      mine = drafted_workflow(installation_id, %{name: "Mine"})
      version(mine)

      assert {:error, %Error{class: :not_found}} = Workflows.get_version(scope, mine.id, 7)
    end

    test "answer not_found across workspaces", %{
      other_scope: other_scope,
      installation_id: installation_id
    } do
      mine = drafted_workflow(installation_id, %{name: "Mine"})
      version(mine)

      assert {:error, error} = Workflows.list_versions(other_scope, mine.id)
      assert error == unknown_id_error(other_scope)

      assert {:error, error} = Workflows.get_version(other_scope, mine.id, 1)
      assert error == unknown_id_error(other_scope)
    end

    test "a viewer may read the history", %{installation_id: installation_id} do
      mine = drafted_workflow(installation_id, %{name: "Mine"})
      version(mine)
      viewer = viewer_scope(installation_id)

      assert {:ok, [_entry]} = Workflows.list_versions(viewer, mine.id)
    end
  end

  # The answer another workspace's identifier gets must be the answer a
  # nonexistent one gets, field for field.
  defp unknown_id_error(scope) do
    {:error, error} = Workflows.get_workflow(scope, Ecto.UUID.generate())
    error
  end

  defp audit_events(installation_id, action) do
    Repo.all(
      from e in AuditEvent,
        where: e.installation_id == ^installation_id and e.action == ^action
    )
  end

  defp viewer_scope(installation_id), do: role_scope(installation_id, "viewer")
  defp editor_scope(installation_id), do: role_scope(installation_id, "editor")
  defp owner_scope(installation_id), do: role_scope(installation_id, "owner")

  defp role_scope(installation_id, role) do
    %Scope{
      installation_id: installation_id,
      member_id: member_id(installation_id),
      role: role
    }
  end

  defp member_id(installation_id) do
    Repo.one!(
      from m in "workspace_members",
        where: m.installation_id == ^Ecto.UUID.dump!(installation_id),
        limit: 1,
        select: type(m.id, Ecto.UUID)
    )
  end

  # Counts the queries one call makes, using the repository's own telemetry
  # event. Deterministic, and it needs no log parsing.
  #
  # A telemetry handler is global, and the suite runs asynchronously, so the
  # count is taken only for events emitted by this test's own process. Ecto
  # emits the event from whichever process ran the query, which is this one.
  defp count_queries(fun) do
    handler = "query-count-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])
    mine = self()

    :telemetry.attach(
      handler,
      [:pumble_automation, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == mine, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  defp internal?(name), do: name |> Atom.to_string() |> String.starts_with?("__")

  defp scope_first?(name, arity) do
    args = List.duplicate(nil, arity - 1)

    try do
      apply(Workflows, name, [%{not: :a_scope} | args])
      false
    rescue
      FunctionClauseError -> true
      BadMapError -> true
    end
  end
end
