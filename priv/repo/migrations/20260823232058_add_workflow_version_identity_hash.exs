defmodule PumbleAutomation.Repo.Migrations.AddWorkflowVersionIdentityHash do
  use Ecto.Migration

  @disable_ddl_transaction true
  @batch_size 500

  @constraints [
    %{
      name: "workflow_versions_source_hash_check",
      expression: "source_hash IS NULL OR source_hash::text ~ '^[0-9a-f]{64}$'::text",
      create_sql: """
      ALTER TABLE workflow_versions
        ADD CONSTRAINT workflow_versions_source_hash_check
        CHECK (source_hash IS NULL OR source_hash ~ '^[0-9a-f]{64}$') NOT VALID
      """
    },
    %{
      name: "workflow_versions_identity_hash_check",
      expression: "identity_hash IS NULL OR identity_hash::text ~ '^[0-9a-f]{64}$'::text",
      create_sql: """
      ALTER TABLE workflow_versions
        ADD CONSTRAINT workflow_versions_identity_hash_check
        CHECK (identity_hash IS NULL OR identity_hash ~ '^[0-9a-f]{64}$') NOT VALID
      """
    },
    %{
      name: "workflow_versions_snapshot_hash_pair_check",
      expression: "(source_hash IS NULL) = (identity_hash IS NULL)",
      create_sql: """
      ALTER TABLE workflow_versions
        ADD CONSTRAINT workflow_versions_snapshot_hash_pair_check
        CHECK ((source_hash IS NULL) = (identity_hash IS NULL)) NOT VALID
      """
    }
  ]

  @indexes [
    %{
      name: "workflow_versions_workflow_id_source_hash_index",
      second_key: "source_hash",
      unique: false,
      create_sql:
        "CREATE INDEX CONCURRENTLY workflow_versions_workflow_id_source_hash_index " <>
          "ON workflow_versions (workflow_id, source_hash)"
    },
    %{
      name: "workflow_versions_workflow_id_identity_hash_index",
      second_key: "identity_hash",
      unique: true,
      create_sql:
        "CREATE UNIQUE INDEX CONCURRENTLY workflow_versions_workflow_id_identity_hash_index " <>
          "ON workflow_versions (workflow_id, identity_hash)"
    }
  ]

  def up do
    execute """
    ALTER TABLE workflow_versions
      ADD COLUMN IF NOT EXISTS source_hash varchar(64),
      ADD COLUMN IF NOT EXISTS identity_hash varchar(64)
    """

    flush()
    execute(&backfill_identity_hashes/0)
    flush()

    execute(&ensure_constraints/0)

    execute """
    ALTER TABLE workflow_versions
      VALIDATE CONSTRAINT workflow_versions_source_hash_check,
      VALIDATE CONSTRAINT workflow_versions_identity_hash_check,
      VALIDATE CONSTRAINT workflow_versions_snapshot_hash_pair_check
    """

    execute(&ensure_indexes/0)
  end

  def down do
    execute(&assert_contract_objects/0)

    drop unique_index(:workflow_versions, [:workflow_id, :identity_hash], concurrently: true)
    drop index(:workflow_versions, [:workflow_id, :source_hash], concurrently: true)

    drop constraint(:workflow_versions, :workflow_versions_snapshot_hash_pair_check)
    drop constraint(:workflow_versions, :workflow_versions_identity_hash_check)
    drop constraint(:workflow_versions, :workflow_versions_source_hash_check)

    alter table(:workflow_versions) do
      remove :source_hash
      remove :identity_hash
    end
  end

  defp backfill_identity_hashes do
    backfill_after(nil)
  end

  defp ensure_indexes do
    Enum.each(@indexes, &ensure_index/1)
  end

  defp ensure_index(spec) do
    rows = index_rows(spec)

    case rows do
      [] ->
        repo().query!(spec.create_sql)

      [row] ->
        repair_or_accept_index(row, spec)

      _unexpected ->
        raise "existing workflow version index name is ambiguous"
    end
  end

  defp index_rows(spec) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT relation.relkind::text,
               target.oid = 'workflow_versions'::regclass,
               index.indisunique,
               index.indisvalid,
               index.indisready,
               index.indislive,
               index.indisprimary,
               index.indisexclusion,
               index.indnkeyatts,
               index.indnatts,
               access_method.amname,
               index.indexprs IS NULL,
               index.indpred IS NULL,
               ARRAY(
                 SELECT pg_get_indexdef(index.indexrelid, key_position, true)
                 FROM generate_series(1, index.indnkeyatts) AS key_position
                 ORDER BY key_position
               ),
               pg_get_indexdef(index.indexrelid) =
                 format(
                   'CREATE %sINDEX %I ON %I.%I USING btree (%I, %I)',
                   CASE WHEN $2::boolean THEN 'UNIQUE ' ELSE '' END,
                   $1::text,
                   current_schema(),
                   'workflow_versions',
                   'workflow_id',
                   $3::text
                 )
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        LEFT JOIN pg_index AS index ON index.indexrelid = relation.oid
        LEFT JOIN pg_class AS target ON target.oid = index.indrelid
        LEFT JOIN pg_am AS access_method ON access_method.oid = relation.relam
        WHERE relation.relname = $1::text
          AND namespace.nspname = current_schema()
        """,
        [spec.name, spec.unique, spec.second_key]
      )

    rows
  end

  defp repair_or_accept_index(row, spec) do
    cond do
      exact_index_definition?(row, spec) and index_usable?(row) ->
        :ok

      exact_index_definition?(row, spec) and index_invalid?(row) ->
        repo().query!("DROP INDEX CONCURRENTLY " <> spec.name)
        repo().query!(spec.create_sql)

      true ->
        raise "existing workflow version index does not match its required definition"
    end
  end

  defp exact_index_definition?(
         [
           "i",
           true,
           unique,
           _valid,
           _ready,
           _live,
           false,
           false,
           2,
           2,
           "btree",
           true,
           true,
           ["workflow_id", second_key],
           true
         ],
         spec
       ) do
    unique == spec.unique and second_key == spec.second_key
  end

  defp exact_index_definition?(_row, _spec), do: false

  defp index_usable?([_, _, _, true, true, true | _rest]), do: true
  defp index_usable?(_row), do: false

  defp index_invalid?([_, _, _, false | _rest]), do: true
  defp index_invalid?(_row), do: false

  defp ensure_constraints do
    Enum.each(@constraints, &ensure_constraint/1)
  end

  defp ensure_constraint(spec) do
    case constraint_rows(spec.name) do
      [] ->
        repo().query!(spec.create_sql)

      [row] ->
        assert_constraint_definition!(row, spec)

      _unexpected ->
        raise "existing workflow version constraint name is ambiguous"
    end
  end

  defp constraint_rows(name) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT relation.oid = 'workflow_versions'::regclass,
               catalog_constraint.contype::text,
               catalog_constraint.convalidated,
               catalog_constraint.condeferrable,
               catalog_constraint.condeferred,
               catalog_constraint.connoinherit,
               catalog_constraint.conislocal,
               catalog_constraint.coninhcount,
               catalog_constraint.conparentid = 0,
               pg_get_expr(catalog_constraint.conbin, catalog_constraint.conrelid, true)
        FROM pg_constraint AS catalog_constraint
        LEFT JOIN pg_class AS relation ON relation.oid = catalog_constraint.conrelid
        WHERE catalog_constraint.conname = $1
          AND catalog_constraint.connamespace = current_schema()::regnamespace
        """,
        [name]
      )

    rows
  end

  defp assert_constraint_definition!(
         [true, "c", validated, false, false, false, true, 0, true, expression],
         spec
       )
       when is_boolean(validated) do
    if expression != spec.expression do
      raise "existing workflow version constraint does not match its required definition"
    end
  end

  defp assert_constraint_definition!(_row, _spec) do
    raise "existing workflow version constraint does not match its required definition"
  end

  defp assert_contract_objects do
    Enum.each(@constraints, fn spec ->
      case constraint_rows(spec.name) do
        [row] -> assert_constraint_definition!(row, spec)
        _unexpected -> raise "required workflow version constraint is absent or ambiguous"
      end
    end)

    Enum.each(@indexes, fn spec ->
      case index_rows(spec) do
        [row] -> assert_index_definition!(row, spec)
        _unexpected -> raise "required workflow version index is absent or mismatched"
      end
    end)
  end

  defp assert_index_definition!(row, spec) do
    if not exact_index_definition?(row, spec) do
      raise "required workflow version index is absent or mismatched"
    end
  end

  defp backfill_after(after_id) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id::text,
               source_definition,
               compiled_definition,
               compiler_version,
               definition_hash,
               required_scopes,
               ARRAY(SELECT value::text FROM unnest(referenced_secret_ids) AS value),
               ARRAY(SELECT value::text FROM unnest(referenced_connection_ids) AS value)
        FROM workflow_versions
        WHERE ($1::uuid IS NULL OR id > $1::uuid)
        ORDER BY id
        LIMIT #{@batch_size}
        """,
        [after_id]
      )

    case rows do
      [] ->
        :ok

      rows ->
        {ids, source_hashes, identity_hashes} = backfill_columns(rows)

        repo().query!(
          """
          UPDATE workflow_versions AS version
          SET source_hash = identity.source_hash,
              identity_hash = identity.identity_hash
          FROM unnest($1::text[], $2::text[], $3::text[])
               AS identity(id, source_hash, identity_hash)
          WHERE version.id = identity.id::uuid
          """,
          [ids, source_hashes, identity_hashes]
        )

        backfill_after(Ecto.UUID.dump!(List.last(ids)))
    end
  end

  defp backfill_columns(rows) do
    rows
    |> Enum.map(&hash_row/1)
    |> Enum.reduce({[], [], []}, &prepend_hash_row/2)
    |> then(fn {ids, source_hashes, identity_hashes} ->
      {Enum.reverse(ids), Enum.reverse(source_hashes), Enum.reverse(identity_hashes)}
    end)
  end

  defp hash_row([
         id,
         source,
         compiled,
         compiler,
         stored_source_hash,
         scopes,
         secrets,
         connections
       ]) do
    source_hash = definition_hash(source)

    if source_hash != stored_source_hash do
      raise "stored workflow version source hash does not match its source definition"
    end

    {id, source_hash,
     identity_hash(%{
       source_definition: source,
       compiled_definition: compiled,
       compiler_version: compiler,
       required_scopes: scopes,
       referenced_secret_ids: secrets,
       referenced_connection_ids: connections
     })}
  end

  defp prepend_hash_row(
         {id, source_hash, identity_hash},
         {ids, source_hashes, identity_hashes}
       ) do
    {[id | ids], [source_hash | source_hashes], [identity_hash | identity_hashes]}
  end

  defp identity_hash(snapshot) do
    snapshot
    |> identity_document()
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp definition_hash(term) do
    term
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp identity_document(snapshot) do
    %{
      "source_definition" => Map.get(snapshot, :source_definition),
      "compiled_definition" => Map.get(snapshot, :compiled_definition),
      "compiler_version" => Map.get(snapshot, :compiler_version),
      "required_scopes" => sorted(Map.get(snapshot, :required_scopes)),
      "referenced_secret_ids" => sorted(Map.get(snapshot, :referenced_secret_ids)),
      "referenced_connection_ids" => sorted(Map.get(snapshot, :referenced_connection_ids))
    }
  end

  defp sorted(nil), do: []
  defp sorted(values) when is_list(values), do: Enum.sort(values)
  defp sorted(value), do: value

  defp canonical_json(term), do: term |> canonicalize() |> Jason.encode!()

  defp canonicalize(term) when is_struct(term), do: term

  defp canonicalize(term) when is_map(term) do
    %Jason.OrderedObject{
      values:
        term
        |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
        |> Enum.sort_by(&elem(&1, 0))
    }
  end

  defp canonicalize(term) when is_list(term), do: Enum.map(term, &canonicalize/1)
  defp canonicalize(term), do: term
end
