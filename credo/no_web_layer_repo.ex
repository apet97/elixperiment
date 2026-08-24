defmodule PumbleAutomation.Checks.NoWebLayerRepo do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Browser and controller modules must not call PumbleAutomation.Repo.
      Tenant queries belong in context modules that take a Scope or a trusted
      installation id derived from a verified job row, callback, or token.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    if web_source?(source_file.filename) do
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  defp web_source?(filename) when is_binary(filename) do
    String.contains?(filename, "lib/pumble_automation_web/")
  end

  defp web_source?(_filename), do: false

  defp traverse(
         {:alias, meta, [{:__aliases__, _, [:PumbleAutomation, :Repo]} | _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "PumbleAutomation.Repo") | issues]}
  end

  defp traverse(
         {{:., meta, [{:__aliases__, _, [:PumbleAutomation, :Repo]}, _fun]}, _call_meta, _args} =
           ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], "PumbleAutomation.Repo") | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message: "Web modules must not use PumbleAutomation.Repo; call a scoped context.",
      trigger: trigger,
      line_no: line_no
    )
  end
end
