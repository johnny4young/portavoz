# sqlite-vec provenance

- Upstream: https://github.com/asg017/sqlite-vec
- Version: v0.1.9
- Tag commit: `e9f598abfa0c06b328d8fe5da9c3760cce74be10`
- Official amalgamation archive: `sqlite-vec-0.1.9-amalgamation.zip`
- Official archive SHA-256: `b87cdda12112657ba5ab8842f0088a4090982eaf41f22b2bd6d495b81765a8c9`
- Vendored C Git blob: `de3176f9ca28a273c5086f1cc995ebf4e3c04c22`
- Vendored C SHA-256: `ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85`
- Header template Git blob: `f49f62f6552b45ac612d236af96979aaba5bac8c`
- Version file Git blob: `1a030947e832763db761663d9f3e5acb42a7bff8`
- Rendered header SHA-256: `4f022d5ff3f97e521c7aef473a6991a7819a4d226be4267d3ee03138904d9968`
- License: MIT selected from upstream's MIT OR Apache-2.0 terms
- License SHA-256: `e49d7859a0fd8d3f8a2a7b81ca1dbddf61bd4f9e981d12908ead721a78c42f32`

The C amalgamation is byte-identical to the official `v0.1.9` Git blob. The
header is deterministically rendered from the official tagged template using
the fixed version, tag commit, and tag-commit timestamp shown above. The
checksum-pinned release ZIP remains the canonical offline acquisition route;
the tagged-blob route is an independent fallback when release-asset transport
is unavailable. Git attributes disable text normalization for these two
vendored artifacts and intentionally preserve upstream whitespace byte for
byte.

Portavoz compiles these files only into the `CSQLiteVecResearch` test target.
Dynamic extension loading is forbidden. No app, CLI, durable schema, meeting
writer, or user-visible query path depends on this code.
