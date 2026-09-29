# WoW.ChromieCraft fast recall

Goal: make the normal path a warm restore rather than a rebuild.

1. GitHub stores only source/control-plane files and exact pins.
2. A compact critical-state snapshot stores database state and sanitized configuration.
3. The proprietary WoW client remains a user-authorized durable payload outside Git; when mounted, it is never re-downloaded.
4. DBC/maps/vmaps/mmaps should be snapshotted after successful extraction and restored as a warm data layer.
5. Wine/DXVK are portable warm-layer archives.
6. Display :88 is brought up with MIT-MAGIC-COOKIE-1 and kept running for the life of the workspace.

Normal command:

```bash
./recall.sh
```

Dry boot without launching the game window:

```bash
WOW_NO_LAUNCH=1 ./recall.sh
```

The recall script never downloads the WoW client implicitly. If the client layer is missing it reports the exact required mount/archive path.
