#!/usr/bin/env python3
"""Record the actual C compiler arguments, then execute the system compiler."""
import json
import os
import sys

arguments = ['-O3', *sys.argv[1:]] if '-c' in sys.argv else sys.argv[1:]
if path := os.environ.get('C3TTP_CC_LOG'):
    with open(path, 'a') as log:
        log.write(json.dumps(arguments) + '\n')
os.execvp('cc', ['cc', *arguments])
