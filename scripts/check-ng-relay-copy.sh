#!/bin/sh
# crates/ng-relay is a copy of the NG service's (~/ng-service/crates/ng-relay):
# the phone and the Monitor must speak the same pairing and sessions. This
# says whether they differ (run after changing either).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)/crates/ng-relay
there=${NG_SERVICE:-$HOME/ng-service}/crates/ng-relay
diff -r -x target "$there/src" "$here/src" && diff -r "$there/tests" "$here/tests" && diff "$there/Cargo.toml" "$here/Cargo.toml" && echo "ng-relay: the same as $there"
