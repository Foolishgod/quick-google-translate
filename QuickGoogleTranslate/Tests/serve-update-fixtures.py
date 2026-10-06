from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
(root / 'port.txt').write_text(str(server.server_port))
print('Local fixture feed server ready.', flush=True)
server.serve_forever()
