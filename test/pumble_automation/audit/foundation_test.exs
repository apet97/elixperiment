defmodule PumbleAutomation.Audit.FoundationTest do
  use PumbleAutomation.DataCase, async: false

  alias PumbleAutomation.Audit.AuditEvent
  alias PumbleAutomation.Audit.Writer
  alias PumbleAutomation.Installations.Installation

  # A scratch table stands in for a business table, the same way the Oban tests
  # do it. It lives and dies inside the sandbox transaction, so the atomicity
  # claim can be proved before any domain schema exists.
  setup do
    Repo.query!("CREATE TEMPORARY TABLE scratch_rows (id uuid PRIMARY KEY) ON COMMIT DROP")
    :ok
  end

  describe "the migration" do
    test "creates the audit_events table" do
      assert %{rows: [[table]]} = Repo.query!("SELECT to_regclass('public.audit_events')::text")
      assert table == "audit_events"
    end

    test "has no updated_at column, because rows are never rewritten" do
      assert "inserted_at" in column_names()
      refute "updated_at" in column_names()
    end

    test "stores metadata as jsonb" do
      assert %{rows: [[type]]} =
               Repo.query!("""
               SELECT data_type FROM information_schema.columns
               WHERE table_name = 'audit_events' AND column_name = 'metadata'
               """)

      assert type == "jsonb"
    end

    test "indexes the tenant timeline, correlation, actor, and resource" do
      %{rows: rows} =
        Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = 'audit_events'")

      definitions = Enum.map_join(rows, "\n", fn [definition] -> definition end)

      assert definitions =~ "(installation_id, inserted_at)"
      assert definitions =~ "(installation_id, action, inserted_at)"
      assert definitions =~ "(correlation_id)"
      assert definitions =~ "(resource_type, resource_id)"
      assert definitions =~ "(actor_type, actor_id)"
    end
  end

  describe "append/3 on the happy path" do
    test "commits the business row and the audit row together" do
      id = Ecto.UUID.generate()

      assert {:ok, %{audit: %AuditEvent{} = event}} =
               Ecto.Multi.new()
               |> insert_scratch_row(id)
               |> Writer.append(:audit, attrs())
               |> Repo.transaction()

      assert scratch_row_count() == 1
      assert audit_count() == 1
      assert event.action == "installation.activated"
      assert %DateTime{} = event.inserted_at
    end

    test "builds the attributes from an earlier step" do
      id = installation_id()

      assert {:ok, %{audit: event}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:installation, fn _repo, _changes -> {:ok, %{id: id}} end)
               |> Writer.append(:audit, fn %{installation: installation} ->
                 attrs(%{installation_id: installation.id, resource_id: installation.id})
               end)
               |> Repo.transaction()

      assert event.installation_id == id
      assert event.resource_id == id
    end

    test "generates a correlation id when the caller omits one" do
      assert {:ok, %{audit: event}} =
               Ecto.Multi.new()
               |> Writer.append(:audit, Map.delete(attrs(), :correlation_id))
               |> Repo.transaction()

      assert {:ok, _uuid} = Ecto.UUID.cast(event.correlation_id)
    end

    test "accepts allowlisted scalar metadata" do
      metadata = %{
        reason: "user_requested",
        http_status: 200,
        retryable: false,
        duration_ms: 12.5
      }

      assert {:ok, %{audit: event}} = append(attrs(%{metadata: metadata}))

      assert event.metadata == %{
               "reason" => "user_requested",
               "http_status" => 200,
               "retryable" => false,
               "duration_ms" => 12.5
             }
    end

    test "defaults metadata to an empty map" do
      assert {:ok, %{audit: event}} = append(attrs())
      assert event.metadata == %{}
    end
  end

  describe "atomicity in both directions" do
    test "a rejected audit row rolls the business change back" do
      id = Ecto.UUID.generate()

      assert {:error, :audit, %Ecto.Changeset{} = changeset, _completed} =
               Ecto.Multi.new()
               |> insert_scratch_row(id)
               |> Writer.append(:audit, attrs(%{metadata: %{token: "leaked"}}))
               |> Repo.transaction()

      refute changeset.valid?
      assert scratch_row_count() == 0
      assert audit_count() == 0
    end

    test "a failing business step rolls the audit row back" do
      assert {:error, :business, :boom, _completed} =
               Ecto.Multi.new()
               |> Writer.append(:audit, attrs())
               |> Ecto.Multi.run(:business, fn _repo, _changes -> {:error, :boom} end)
               |> Repo.transaction()

      assert audit_count() == 0
    end

    test "a business step that fails after a valid audit row leaves nothing behind" do
      id = Ecto.UUID.generate()

      assert {:error, :business, :boom, _completed} =
               Ecto.Multi.new()
               |> insert_scratch_row(id)
               |> Writer.append(:audit, attrs())
               |> Ecto.Multi.run(:business, fn _repo, _changes -> {:error, :boom} end)
               |> Repo.transaction()

      assert scratch_row_count() == 0
      assert audit_count() == 0
    end
  end

  describe "metadata rules" do
    test "rejects a key that is not on the allowlist" do
      assert Enum.any?(metadata_errors(%{surprise: "value"}), &(&1 =~ "allowlist"))
      assert audit_count() == 0
    end

    test "refuses every secret-shaped and payload-shaped key by name" do
      for key <- [
            :token,
            :access_token,
            :client_secret,
            :code,
            :password,
            :signature,
            :authorization,
            :body,
            :raw_payload,
            :message_content
          ] do
        assert Enum.any?(metadata_errors(%{key => "x"}), &(&1 =~ "names a secret")),
               "expected #{key} to be refused by name"
      end

      assert audit_count() == 0
    end

    test "rejects non-scalar values, including nil" do
      for value <- [%{nested: 1}, [1, 2], nil, {:a, :b}] do
        assert Enum.any?(metadata_errors(%{reason: value}), &(&1 =~ "must be a string")),
               "expected #{inspect(value)} to be refused"
      end
    end

    test "rejects metadata that is not a map" do
      assert metadata_errors("not a map") != []
      assert metadata_errors([1, 2, 3]) != []
      assert audit_count() == 0
    end

    test "enforces the encoded byte limit" do
      oversized = String.duplicate("x", AuditEvent.max_metadata_bytes() + 1)

      assert Enum.any?(metadata_errors(%{reason: oversized}), &(&1 =~ "byte limit"))
      assert audit_count() == 0
    end

    test "accepts metadata that sits just under the byte limit" do
      # 64 bytes of slack covers the JSON braces, quotes, and the key itself.
      sized = String.duplicate("x", AuditEvent.max_metadata_bytes() - 64)

      assert {:ok, _changes} = append(attrs(%{metadata: %{reason: sized}}))
    end

    test "no allowlisted key would be refused by the denied-key patterns" do
      offenders = Enum.filter(AuditEvent.allowed_metadata_keys(), &AuditEvent.denied_key?/1)

      assert offenders == [],
             "these allowlisted metadata keys read like secrets or payloads: #{inspect(offenders)}"
    end
  end

  describe "action codes" do
    test "accepts a namespaced code in a reserved namespace" do
      for action <- ["oauth.install_failed", "credential.rotated", "workflow.published"] do
        assert {:ok, _changes} = append(attrs(%{action: action}))
      end
    end

    test "rejects a code with no namespace" do
      assert action_errors("activated") != []
    end

    test "rejects a code in an unreserved namespace" do
      assert Enum.any?(action_errors("marketing.clicked"), &(&1 =~ "unreserved"))
    end

    test "rejects a malformed code" do
      for action <- [
            "Installation.Activated",
            "installation..activated",
            "installation activated"
          ] do
        assert action_errors(action) != [], "expected #{action} to be refused"
      end
    end
  end

  describe "tenancy" do
    test "requires an installation for an ordinary action" do
      assert {:error, :audit, changeset, _completed} = append(attrs(%{installation_id: nil}))
      assert errors_on(changeset).installation_id != []
      assert audit_count() == 0
    end

    test "allows a missing installation only in the pre-install OAuth namespace" do
      assert {:ok, %{audit: event}} =
               append(
                 attrs(%{
                   installation_id: nil,
                   action: "oauth.install_failed",
                   actor_type: "system",
                   actor_id: nil,
                   resource_type: nil,
                   resource_id: nil,
                   metadata: %{reason: "state_mismatch"}
                 })
               )

      assert event.installation_id == nil
      assert event.metadata == %{"reason" => "state_mismatch"}
    end

    test "keeps each tenant's events on its own installation" do
      first = installation_id()
      second = installation_id()

      for id <- [first, first, second] do
        assert {:ok, _changes} = append(attrs(%{installation_id: id}))
      end

      assert count_for(first) == 2
      assert count_for(second) == 1
    end

    test "accepts an actor that does not belong to the audited installation" do
      # A support administrator acting on someone else's installation is a real
      # and important case. It must be recordable, because refusing to record it
      # would make the most sensitive action the least accountable one. The row
      # is owned by the installation acted upon, not by the actor.
      assert {:ok, %{audit: event}} =
               append(
                 attrs(%{
                   actor_type: "system",
                   actor_id: "support-console",
                   action: "admin.installation_suspended"
                 })
               )

      assert event.actor_id == "support-console"
      assert event.installation_id != nil
    end

    test "rejects an unknown actor type" do
      assert {:error, :audit, changeset, _completed} = append(attrs(%{actor_type: "root"}))
      assert errors_on(changeset).actor_type != []
    end
  end

  describe "append_best_effort/1" do
    test "writes a noncritical diagnostic outside a transaction" do
      assert Writer.append_best_effort(attrs(%{action: "security.probe_observed"})) == :ok
      assert audit_count() == 1
    end

    test "reports an invalid event without raising and without writing" do
      assert Writer.append_best_effort(attrs(%{metadata: %{token: "x"}})) ==
               {:error, :audit_append_failed}

      assert audit_count() == 0
    end

    test "reports a missing tenant without raising" do
      assert Writer.append_best_effort(attrs(%{installation_id: nil})) ==
               {:error, :audit_append_failed}
    end
  end

  describe "the append-only API surface" do
    test "the writer exposes no update and no delete" do
      assert mutating_functions(Writer) == []
    end

    test "the schema exposes no update and no delete" do
      assert mutating_functions(AuditEvent) == []
    end

    test "the writer exposes append, flood-limited denied, and actor helpers" do
      exported =
        for {name, _arity} <- Writer.__info__(:functions),
            string = Atom.to_string(name),
            not String.starts_with?(string, "__"),
            do: string

      assert Enum.sort(exported) == [
               "actor",
               "append",
               "append_best_effort",
               "append_denied",
               "denied_per_minute"
             ]
    end
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        installation_id: installation_id(),
        actor_type: "user",
        actor_id: "user-1",
        action: "installation.activated",
        resource_type: "installation",
        resource_id: Ecto.UUID.generate(),
        correlation_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  # Audit rows point at a real installation now that the foreign key exists, so
  # a test that needs a tenant inserts one instead of inventing a UUID.
  defp installation_id do
    {:ok, installation} =
      %Installation{}
      |> Installation.changeset(%{pumble_workspace_id: "ws-" <> Ecto.UUID.generate()})
      |> Repo.insert()

    installation.id
  end

  defp append(attrs) do
    Ecto.Multi.new()
    |> Writer.append(:audit, attrs)
    |> Repo.transaction()
  end

  defp metadata_errors(metadata) do
    {:error, :audit, changeset, _completed} = append(attrs(%{metadata: metadata}))

    errors_on(changeset).metadata
  end

  defp action_errors(action) do
    {:error, :audit, changeset, _completed} = append(attrs(%{action: action}))

    errors_on(changeset).action
  end

  defp mutating_functions(module) do
    for {name, arity} <- module.__info__(:functions),
        string = Atom.to_string(name),
        String.contains?(string, "update") or String.contains?(string, "delete"),
        do: {name, arity}
  end

  defp column_names do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'audit_events'"
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp count_for(installation_id) do
    Repo.aggregate(from(e in AuditEvent, where: e.installation_id == ^installation_id), :count)
  end

  defp audit_count, do: Repo.aggregate(AuditEvent, :count)

  defp insert_scratch_row(multi, id) do
    Ecto.Multi.insert_all(multi, :row, "scratch_rows", [%{id: Ecto.UUID.dump!(id)}])
  end

  defp scratch_row_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM scratch_rows")
    count
  end
end
