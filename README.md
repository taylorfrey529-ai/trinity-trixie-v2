# WoW.ChromieCraft on TrinityCore

Fast-recall workspace for a local loopback-only World of Warcraft 3.3.5a (build 12340) client and pinned TrinityCore 3.3.5 server.

## Pins

- TrinityCore commit: `f5f9bac4fa74da42e2dce419309362aede578e9d`
- TrinityCore tree: `39b1b4e92c9efc254a239645d1a6478360c8df54`
- Client build: `12340`
- Client archive SHA-256: `fed612104085999e8875f077a5ed1e055aac7faaab413a33fed6a23bc2339732`
- Wine: `11.18-staging-amd64-wow64`
- DXVK: `3.1.1`
- Persistent virtual display: `:88`, `2560x1440x24`

## Fast path

```bash
./preflight-fast.sh
./recall.sh
```

`recall.sh` prepares the portable runtime, authenticates/starts Xvfb :88, starts the server only after `server.sh preflight` passes, verifies the client layer, configures local realmlist, then launches.

The WoW client is intentionally not stored in this public repository. Mount an authorized pre-extracted client at `client/ChromieCraft_3.3.5a/` or provide `CHROMIECRAFT_ARCHIVE` to a locally supplied archive.

See `FAST-RECALL.md` for the persistence model. Historical validated state is kept in the private recovery snapshot, not the public repository.
