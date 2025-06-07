#!/bin/bash
set -e
if [ -f /var/www/html/index.html ]; then
  rm -f /var/www/html/index.html
fi
