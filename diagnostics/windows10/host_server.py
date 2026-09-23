#!/usr/bin/env python3
"""Loopback-only package server and bounded guest evidence receiver."""
import argparse
import email.policy
import email.parser
import http.server
import json
from pathlib import Path
import shutil
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('--installer', required=True, type=Path)
parser.add_argument('--guest-script', required=True, type=Path)
parser.add_argument('--candidate', type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--port', type=int, default=8765)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
guest_output = args.output / 'guest'
guest_output.mkdir(exist_ok=True)
routes = {'/installer.exe': args.installer, '/Test-Windows10Startup.ps1': args.guest_script}
if args.candidate:
    routes['/candidate.exe'] = args.candidate

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            body = b'ok\n'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        path = routes.get(self.path)
        if path is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(path.stat().st_size))
        self.end_headers()
        with path.open('rb') as source:
            shutil.copyfileobj(source, self.wfile, 1024 * 1024)

    def do_POST(self):
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if size <= 0 or size > 40 * 1024 * 1024:
                raise ValueError('Evidence request exceeds allowed size')
            data = self.rfile.read(size)
            if len(data) != size:
                raise ValueError('Incomplete request')
            if self.path == '/complete':
                value = json.loads(data.decode('utf-8-sig'))
                (args.output / 'completion.json').write_text(json.dumps(value, indent=2), encoding='utf-8')
            elif self.path.startswith('/results/'):
                relative = urllib.parse.unquote(self.path.removeprefix('/results/'))
                dest = (guest_output / relative).resolve()
                if not dest.is_relative_to(guest_output.resolve()) or dest == guest_output.resolve():
                    raise ValueError('Invalid evidence path')
                # WebClient.UploadFile uses multipart/form-data by default.
                ctype = self.headers.get('Content-Type', '')
                if ctype.lower().startswith('multipart/form-data'):
                    prefix = ('Content-Type: ' + ctype + '\r\nMIME-Version: 1.0\r\n\r\n').encode()
                    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(prefix + data)
                    parts = list(message.iter_parts())
                    if len(parts) != 1:
                        raise ValueError('Expected one evidence file')
                    data = parts[0].get_payload(decode=True)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'ok')
        except Exception as error:
            self.send_error(400, str(error))

http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
