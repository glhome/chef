define_upgrade do
  if Partybus.config.bootstrap_server # TODO: do we want this?
    rmq = Partybus.config.running_server["private_chef"]["rabbitmq"]
    return unless rmq["enable"]

    start_services(["rabbitmq"])

    [
      [rmq["user"], "password"],
      [rmq["actions_user"], "actions_password"],
      [rmq["management_user"], "management_password"]
    ].each do |name, passname|
      pass = Partybus.config.secrets.get('rabbitmq', passname)
      run_command("/opt/opscode/embedded/bin/rabbitmqctl change_password #{name} #{pass}",
                  log_msg: "rabbitmq password upgrade for user #{name}")
    end

    stop_services(["rabbitmq"])
  end
end
