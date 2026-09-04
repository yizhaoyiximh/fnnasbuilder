#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
exec ../Scripts-build-dmg.sh
