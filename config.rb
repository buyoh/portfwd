
v1 = p_conn(host: 'portfwd', check_tcps: [{host: 'example.com', port: 20022}])
v2 = p_conn(host: 'xxyyzz', check_tcps: [{host: 'example.com', port: 12345}])

v1.then(v2)
