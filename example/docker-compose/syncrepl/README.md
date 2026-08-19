# One provider and one consumer

This local example starts one writable OpenLDAP provider and one read-only consumer. The consumer verifies the provider over LDAPS and is also available as an LDAPS read endpoint inside the Compose network.

The image's default provider entries contain sample users with the password `changeit`. Do not expose this example or use it as a production configuration. Production deployments should provide their own `/opt/ldifs/init_org_entries.ldif` and certificates from their normal CA.

## Start the example

Install Docker Compose and OpenSSL, then run these commands from this directory:

```sh
sh ./generate-secrets.sh
docker compose up -d
```

The generator never overwrites existing secrets or certificates.
If the initial generation stops partway through, remove its incomplete `tls/` and `secrets/` output before trying again.
TLS files can be rotated together and both nodes restarted because their persisted configuration stores file paths, not the CA contents.
Changing the replication password after initialization requires updating the provider's `uid=replicator,DC=example,DC=com` entry and the consumer's `olcSyncrepl` credential; changing the secret file or recreating only config volumes is insufficient.
Changing an administrator secret after initialization likewise does not update the persisted root password.
To discard the example data instead, use the destructive reset below and replace the relevant secrets before restarting.
On POSIX hosts, the generator creates the `tls/` directory and private keys with owner-only permissions.
On Windows, `chmod` does not configure NTFS ACLs; protect the example directory with Windows ACLs or run the entire example from WSL on its Linux filesystem.
The entrypoint safely stages the read-only key mounts whether the container sees them as service-readable or protected root-readable sources.
Keep `tls/ca.key` private; Compose does not mount it into a container.

The two administrator secrets are distinct, but each is mounted in its node at the image default, `/run/secrets/ldap-admin-password`.
The shared replication password is mounted at `/run/secrets/ldap-replication-password`.
TLS auto-detection enables TLS after it finds each node's public certificate and key in either supported TLS source layout.
Only the consumer mounts `ca.crt`: it uses that CA for syncrepl and LDAP CLI commands.
The provider accepts the consumer's simple-bind password and does not request a client certificate.

No startup ordering is required. The consumer retries while the provider initializes.

## Verify replication

Initial synchronization can take a few seconds.
Run the query below; if it reports that the server is unavailable or the base entry is absent, wait briefly and repeat it.
`ldapsearch` reads the terminator-free consumer administrator password created by `generate-secrets.sh` directly from its mounted secret:

```sh
docker compose exec consumer ldapsearch -LLL -x -H ldaps://consumer \
  -D 'uid=admin,DC=example,DC=com' -y /run/secrets/ldap-admin-password \
  -b 'DC=example,DC=com' '(objectClass=*)' dn
```

Applications write to the provider. The consumer copies those changes and rejects local writes.

## Operational constraints

- Both nodes must use the same organization DN, compatible schemas, and the same effective `LDAP_INIT_PPOLICY_DEFAULT_DN`.
- Each node must have its own config and data volumes. Never share these volumes between nodes.
- The provider certificate SAN must match `provider`, the hostname in `LDAP_INIT_REPLICATION_PROVIDER_URI`.
  The consumer certificate SAN matches its `consumer` read-endpoint hostname.
- The replication password file may end with LF or CRLF.
  Its value cannot contain a line break, double quote, or backslash because OpenLDAP persists it inside a quoted `olcSyncrepl` value.
- During initialization, administrator password files may end with LF or CRLF; quotes and backslashes are valid administrator-password characters.
  The generator deliberately omits a terminator because OpenLDAP clients using `-y` treat every file byte, including LF or CRLF, as password data.
- The role settings are first-initialization inputs. Changing them or the secret later does not update the persisted replication configuration.
- OpenLDAP stores the replication password in plaintext in the consumer's config volume. Protect that volume.

Use `docker compose down` to stop the example while keeping its data.
Use `docker compose down --volumes` to permanently delete both LDAP databases and their configuration.
Before the next start, replace any administrator or replication secret whose password the reset is intended to change.
Generated `tls/` and `secrets/` files remain on the host; remove them separately only when they are no longer needed.
