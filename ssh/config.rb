# Each p_conn starts `ssh <host>` with the ssh config rendered from config.erb.
#   host:       a Host in config.erb
#   check_tcps: TCP ports on this machine which can be connected to while the connection is up.
#               Checked after starting ssh and periodically. The connection is restarted if any of them is closed.
#               Here they are the LocalForward ports in config.erb, which ssh opens after the connection is established.
#               (connected and closed without sending data: the remote end of the forwarding is not checked.
#               Each check reaches the local sshd through the RemoteForward, and is logged as a disconnection.
#               Forward the LocalForward to another remote port to avoid it)
v1 = p_conn(host: 'portfwd', check_tcps: [{host: 'localhost', port: 20080}])
v2 = p_conn(host: 'portfwd2', check_tcps: [{host: 'localhost', port: 20088}])

# portfwd2 is started after portfwd is up
v1.then(v2)
