# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

if Code.ensure_loaded?(Ash) do
  defmodule MishkaPay.Ash.Inbox.Fail do
    @moduledoc """
    After the inbox's last try: marks the event `:failed` and keeps why, from the `:error` argument
    AshOban gives its `on_error` action.
    """

    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      error = Ash.Changeset.get_argument(changeset, :error)

      Ash.Changeset.force_change_attributes(changeset,
        status: :failed,
        last_error: error |> message() |> String.slice(0, 2_000)
      )
    end

    defp message(%{__exception__: true} = error), do: Exception.message(error)
    defp message(nil), do: "unknown"
    defp message(other), do: inspect(other)
  end
end
