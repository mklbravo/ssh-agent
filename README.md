# SSH agent container

An unprivileged OpenSSH agent with a Unix-socket proxy for trusted consumers
running with different UIDs. Generates one persistent Ed25519 identity on first
startup, loads it, and prints its public key and fingerprint on every startup.

## Architecture

```text
Consumer (any UID, supplementary GID 2522)
    -> /run/ssh-agent/auth.sock (group-accessible socat socket)
    -> /var/lib/ssh-agent/keys/.agent.sock (private OpenSSH socket)
    -> ssh-agent (UID 2521, GID 2522)
```

OpenSSH verifies peer UIDs in addition to filesystem permissions. Merely making
its socket group-accessible does not allow different UIDs to use it. `socat`
connects with the agent's UID and deliberately makes GID 2522 the authorization
boundary for the shared socket. Neither socket listens on TCP.

`tini` forwards signals and reaps orphaned workers. The Bash entrypoint starts
both services, loads the identity before starting the proxy, and stops the
container if either service exits. The proxy allows at most 16 concurrent worker
processes. Each identity must have its own pair of key and socket volumes;
nonblocking locks prevent cooperating instances from sharing either volume.

## Start

Requires Docker Engine on Linux, Docker Compose v2 and an image already published
to GHCR. Replace `your-owner` with the GitHub user or organization that owns the
repository (and adjust the repository name if it is not `ssh-agent`).

```sh
export SSH_AGENT_IMAGE=ghcr.io/your-owner/ssh-agent:latest
docker compose -f examples/docker-compose.yml up -d
docker compose -f examples/docker-compose.yml logs ssh-agent
```

The example requires `SSH_AGENT_IMAGE` explicitly and never builds locally. For
controlled deployments, use a reviewed commit-SHA tag or, preferably, an immutable
image digest instead of `latest`. Authenticate with `docker login ghcr.io` first
if the published package is private. You can also run Compose from `examples/`,
where it discovers `docker-compose.yml` without the `-f` option.

Copy the line beginning with `ssh-ed25519` from the logs to the target service,
such as a GitHub deploy key. Only the public key and its fingerprint are logged.
The public key is not a secret, but it can reveal identity relationships: control
access to logs accordingly.

The supplied `examples/docker-compose.yml` disables networking for the agent, makes its root
filesystem read-only, drops all capabilities, prevents privilege escalation,
and sets process, memory, CPU and log-size limits. These settings are runtime
controls: use equivalent controls if deploying without this Compose file.

## Connect a consumer

Add the following service to the same Compose project, replacing its image with
your existing application image. The application image must contain its own SSH
client. It needs network access to the destination, unlike the agent service.

```yaml
services:
  app:
    image: your-existing-application:tag
    group_add:
      - "2522"
    environment:
      SSH_AUTH_SOCK: /run/ssh-agent/auth.sock
    volumes:
      - agent-socket:/run/ssh-agent:ro
    depends_on:
      ssh-agent:
        condition: service_healthy
```

`group_add` adds a supplementary numeric group without changing the application's
UID or primary GID. No matching group name is required in `/etc/group`. An image
that switches users and resets supplementary groups must explicitly preserve
GID 2522. Different user-namespace mappings may also require deployment-specific
ID mapping; the numeric GID must map to the same kernel identity.

Mount the socket **directory**, not the socket file: the proxy recreates its
socket on restart. For a separate Compose project, declare the existing socket
volume as external using its actual Docker volume name. Never mount the key
volume into a consumer.

A read-only socket-volume mount prevents filesystem modifications; it does
**not** prevent agent requests or make the SSH protocol read-only.

## Storage and permissions

| Resource | Owner UID:GID | Mode | Purpose |
| --- | --- | --- | --- |
| `/var/lib/ssh-agent/keys` | `2521:2522` | `0700` | Private persistent volume |
| `id_ed25519` inside that volume | `2521:2522` | `0600` | Private identity |
| `.agent.sock` inside that volume | `2521:2522` | Owner-only | Private agent socket |
| `/run/ssh-agent` | `2521:2522` | `0710` | Shared socket directory |
| `/run/ssh-agent/auth.sock` | `2521:2522` | `0660` | Consumer access via GID 2522 |

Fresh Docker-managed named volumes inherit the prepared image directories'
ownership and permissions. Existing volumes and host bind mounts must already
have the documented ownership/modes. Startup rejects incorrect permissions
instead of running as root to repair them. Reserve GID 2522 for this purpose.

Keys are generated only when the private and public files are both absent. An
existing private key is validated and its public key regenerated from it. Invalid,
encrypted, non-Ed25519 or incorrectly permissioned private keys cause startup to
fail, not silently replace the identity. A public key without its private key
also causes startup to fail. Do not modify the volumes while the service runs.

Normal container recreation preserves the identity. **Deleting the key volume,
including with `docker compose -f examples/docker-compose.yml down -v`, destroys
it.** Back up that volume using
a trusted mechanism and protect backups as private keys. For deliberate rotation,
stop the service, arrange a new key volume, and replace/revoke the old public key
at every destination. There is no automatic key rotation.

## Security boundaries

- The private key has no passphrase, so startup is unattended. Filesystem
  permissions are not encryption at rest. Use encrypted host storage and secure
  backups when required by the threat model.
- Anyone able to access the shared socket can authenticate using the loaded key.
  The raw proxy does not filter agent operations: consumers can also add/remove
  identities or lock the agent, affecting other consumers. Only share it within
  one trust boundary. Do not expose it to untrusted builds or PR code.
- Do not forward this agent to untrusted hosts. Prefer one narrowly scoped deploy
  identity per project or environment, with read-only access where possible.
- Client-requested PKCS#11/FIDO provider loading is disabled. The proxy does not
  implement independent SSH authorization or destination restrictions.
- Consumer root and host administrators remain trusted. This container does not
  protect keys from Docker administrators, host root or a compromised agent
  process. Resource limits mitigate, but cannot eliminate, denial of service by
  an authorized consumer.
- Host key verification belongs to consumers. Configure trusted `known_hosts`;
  do not disable `StrictHostKeyChecking` to make connections work.

## Image filesystem layout

`rootfs/` mirrors the container filesystem. The Dockerfile copies the entire tree
to `/` with root ownership, preserving individual file modes. The entrypoint lives
at `rootfs/usr/local/bin/ssh-agent-entrypoint` and is executable. Add future image
files under their destination paths in `rootfs/` without adding more `COPY`
instructions; set executable bits only on files that need them. Do not place
private keys or secrets in this tree.

## GitHub Actions

- `.github/workflows/pr.yml`: image build and Bash entrypoint syntax checks on PRs
  targeting `main`; no push or publishing credentials.
- `.github/workflows/image.yml`: build on pushes to `main`, generate a CycloneDX
  SBOM, scan configuration/secrets and block HIGH/CRITICAL image vulnerabilities
  with Trivy, including vulnerabilities without a fix. Only after all checks
  pass, push the **same scanned image** to `ghcr.io/<owner>/<repository>` with
  `latest` and full commit-SHA tags.
- Scheduled/manual runs rebuild and scan without publishing, only on `main`.
  Manual runs targeting other branches are skipped. This assesses a fresh build,
  not necessarily the bytes of a previously published image.
- SBOMs are workflow artifacts retained for 30 days. An SBOM inventories software;
  it is not a security guarantee, signature or provenance attestation.

Publication uses the repository's `GITHUB_TOKEN`; no personal access token is
needed. Repository/organization policy must allow GHCR publication. Configure
package visibility in GitHub as appropriate. Protect `main` with required PR
checks (`Bash syntax` and `Image build`) to prevent direct changes bypassing
review. In repository Settings > Code security, enable Dependabot alerts and
Dependabot security updates. The Dependabot configuration schedules Docker and
GitHub Actions version updates against the default branch; keep `main` as the
default branch.

The initial CI target is `linux/amd64`. Debian and Trivy images are pinned by
digest; GitHub Actions currently use major-version references. Dependabot proposes
base-image and Action updates; review them before merging. Update the pinned
`TRIVY_IMAGE` in the security workflow separately. Action SHA pinning remains a
hardening task: current upstream SHAs could not be queried because `gh` was not
available in the implementation environment.

No local build, runtime test or workflow validation has been executed as part of
this implementation. Validate startup/restart persistence, cross-UID access,
rejection without GID 2522, shutdown behavior and security scans before production.
