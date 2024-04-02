
v1 = p_conn(host: 'portfwd', check_tcps: [{host: 'localhost', port: 8080}])
v2 = p_conn(host: 'portfwd2', check_tcps: [{host: 'localhost', port: 8888}])

v1.then(v2)
