# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaPay.Registry do
  @moduledoc """
  mishka_installer's plugin registry, for a project outside Mishka CMS. List it first in the
  application's children, before the project's own plugins (`mix igniter.install mishka_pay`
  does); Mishka Pay's application starts the providers, which register as soon as it is up:

      children = [
        MishkaPay.Registry,
        MyApp.Pay.Keys,
        ...
      ]

  mishka_installer leaves its own registry (its event and compile handlers and its Mnesia repo)
  out of its tree when it is compiled for a test run, and a dependency is compiled in the project's
  environment, so a project's `MIX_ENV=test` would run with no registry and no plugin could
  register. This supervisor starts only the parts that are not running: none when mishka_installer
  started them itself, and none inside Mishka CMS, whose core starts them before any extension.
  """

  use Supervisor

  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Installer.CompileHandler

  @parts [CompileHandler, EventHandler, MishkaInstaller.MnesiaRepo]

  @doc false
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The registry parts not running yet, in mishka_installer's order."
  @spec missing() :: [module()]
  def missing do
    (@parts -- MishkaInstaller.Application.supervised_children())
    |> Enum.reject(&Process.whereis/1)
  end

  @impl true
  def init(_opts), do: Supervisor.init(missing(), strategy: :one_for_one)
end
