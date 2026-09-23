#!/usr/bin/env python3
import json
from pathlib import Path
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(sys.argv[1])
connection = sock.makefile('rwb', buffering=0)
greeting = json.loads(connection.readline())
def command(name, arguments=None):
    message = {'execute': name}
    if arguments is not None:
        message['arguments'] = arguments
    connection.write(json.dumps(message).encode() + b'\n')
    while True:
        response = json.loads(connection.readline())
        if 'return' in response or 'error' in response:
            if 'error' in response:
                raise RuntimeError(response['error'])
            return response['return']
command('qmp_capabilities')
if sys.argv[2] == '--boot-key':
    command('send-key', {'keys':[{'type':'qcode', 'data':'ret'}]})
    sock.close()
    sys.exit(0)
command('screendump', {'filename': str(Path(sys.argv[2]).resolve())})
if len(sys.argv) > 3:
    evidence = {'greeting': greeting}
    for name, arguments in [('query-cpus-fast', None), ('query-cpu-model-expansion', {'type':'full', 'model':{'name':'host'}})]:
        try:
            evidence[name] = command(name, arguments)
        except Exception as error:
            evidence[name] = {'error':str(error)}
    Path(sys.argv[3]).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
sock.close()
