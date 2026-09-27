#!/bin/sh
# Regenerates lib/src/sbapi/ from sing-box's daemon/started_service.proto (tool/proto, taken
# from the sing-box release that tool/bin holds). Needs protoc in tool/bin/protoc (a
# protocolbuffers/protobuf release, not in git) and `dart pub global activate protoc_plugin`.
set -e
cd "$(dirname "$0")/.."
plugin="${LOCALAPPDATA:+$LOCALAPPDATA/Pub/Cache/bin/protoc-gen-dart.bat}"
plugin="${plugin:-$HOME/.pub-cache/bin/protoc-gen-dart}"
tool/bin/protoc/bin/protoc --plugin=protoc-gen-dart="$plugin" --dart_out=grpc:lib/src/sbapi \
  -Itool/proto -Itool/bin/protoc/include tool/proto/started_service.proto google/protobuf/empty.proto
